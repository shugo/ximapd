# $Id$
# Copyright (C) 2005  Shugo Maeda <shugo@ruby-lang.org>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

require "socket"
require "fcntl"
require "monitor"
require "net/imap"
require "pstore"
require "yaml/store"
require "find"
require "fileutils"
require "digest/md5"
require "iconv"
require "nkf"
require "date"
require "set"
require "logger"
require "timeout"
require "optparse"
require "sdbm"
require "rmail/parser"

require "ximapd/sequence"
require "ximapd/mail-store"
require "ximapd/mailbox"
require "ximapd/mail"
require "ximapd/session"
require "ximapd/command"
require "ximapd/backend"

now = DateTime.now
unless defined?(now.to_time)
  class DateTime
    def to_time
      d = new_offset(0)
      d.instance_eval {
        Time.utc(year, mon, mday, hour, min, sec,
                 (sec_fraction * 86400000000).to_i)
      }.getlocal
    end

    def to_datetime
      return self
    end
  end

  class Time
    def to_time
      return getlocal
    end

    def to_datetime
      jd = DateTime.civil_to_jd(year, mon, mday, DateTime::ITALY)
      fr = DateTime.time_to_day_fraction(hour, min, [sec, 59].min) +
           usec.to_r/86400000000
      of = utc_offset.to_r/86400
      DateTime.new0(DateTime.jd_to_ajd(jd, fr, of), of, DateTime::ITALY)
    end
  end
end

class Ximapd
  VERSION = "0.1.0"
  REVISION = "$Revision$".slice(/\A\$Revision: (.*) \$\z/, 1)
  DATE = "$Date$".slice(/\d\d\d\d-\d\d-\d\d/)

  LOG_SHIFT_AGE = 10
  LOG_SHIFT_SIZE = 1 * 1024 * 1024
  MAX_CLIENTS = 10
  TIMEZONE = Time.now.strftime("%z")

  def initialize
    @args = nil
    @config = {}
    @server = nil
    @mail_store = nil
    @logger = nil
    @threads = []
    @sessions = {}
    @option_parser = OptionParser.new { |opts|
      opts.banner = "usage: ximapd [options]"
      opts.separator("")
      opts.separator("options:")
      define_options(opts, @config, OPTIONS)
      opts.separator("")
      define_options(opts, @config, ACTIONS)
    }
    @max_clients = nil
  end

  def run(args)
    begin
      @args = args
      parse_options(@args)
      @server = nil
      @config["logger"] = @logger
      @max_clients = @config["max_clients"] || MAX_CLIENTS
      @threads = []
      @sessions = {}
      init_profiler if @config["profile"]
      send(@config["action"])
    rescue StandardError => e
      STDERR.printf("ximapd: %s\n", e)
      @logger.log_exception(e) if @logger
    end
  end

  private

  def define_options(option_parser, config, options)
    for option in options
      option.define(option_parser, config)
    end
  end

  def parse_options(args)
    begin
      @option_parser.parse!(args)
      @config["action"] ||= "help"
      if @config["action"] != "help" && @config["action"] != "version"
        config_file = File.expand_path(@config["config_file"] || "~/.ximapd")
        config = File.open(config_file) { |f|
          if f.stat.mode & 0004 != 0
            raise format("%s is world readable", config_file)
          end
          YAML.load(f)
        }
        @config = config.merge(@config)
        check_config(@config)
        path = @config["plugin_path"] ||
          File.join(@config["data_dir"], "plugins")
        Plugin.directories = path.split(File::PATH_SEPARATOR).collect { |dir|
          File.expand_path(dir)
        }
        @logger = open_logger
      end
    rescue StandardError => e
      raise if @config["debug"]
      STDERR.printf("ximapd: %s\n", e)
      exit(1)
    end
  end

  def init_profiler
    require "prof"
    case @config["profiler_clock_mode"] || ENV["RUBY_PROF_CLOCK_MODE"]
    when "gettimeofday"
      Prof.clock_mode = Prof::GETTIMEOFDAY
      $stderr.puts("use gettimeofday(2) for profiling") if @config["verbose"]
    when "cpu"
      if ENV.key?("RUBY_PROF_CPU_FREQUENCY")
        Prof.cpu_frequency = ENV["RUBY_PROF_CPU_FREQUENCY"].to_f
      else
        begin
          open("/proc/cpuinfo") do |f|
            f.each_line do |line|
              s = line.slice(/cpu MHz\s*:\s*(.*)/, 1)
              if s
                Prof.cpu_frequency = s.to_f * 1000000
                break
              end
            end
          end
        rescue Errno::ENOENT
        end
      end
      Prof.clock_mode = Prof::CPU
      $stderr.puts("use CPU clock counter for profiling") if @config["verbose"]
    else
      Prof.clock_mode = Prof::CLOCK
      $stderr.puts("use clock(3) for profiling") if @config["verbose"]
    end
  end

  def open_logger
    if @config["debug"]
      logger = Logger.new(STDERR)
      logger.level = Logger::DEBUG
    else
      log_file = @config["log_file"] ||
        File.expand_path("ximapd.log", @config["data_dir"])
      FileUtils.mkdir_p(File.dirname(log_file))
      shift_age = @config["log_shift_age"] || LOG_SHIFT_AGE
      shift_size = @config["log_shift_size"] || LOG_SHIFT_SIZE
      logger = Logger.new(log_file, shift_age, shift_size)
      log_level = (@config["log_level"] || "INFO").upcase
      logger.level = Logger.const_get(log_level)
    end
    logger.datetime_format = "%Y-%m-%dT%H:%M:%S "
    if @config["action"] != "start"
      for m in [:fatal, :error, :warn]
        class << logger; self; end.send(:define_method, m) do |s|
          STDERR.printf("ximapd: %s\n", s)
          super(s)
        end
      end
      if @config["verbose"]
        def logger.info(s)
          puts(s)
          super(s)
        end
      end
    end
    def logger.log_exception(e, msg = nil, severity = Logger::ERROR)
      if msg
        add(severity, "#{msg}: #{e.class}: #{e.message}")
      else
        add(severity, "#{e.class}: #{e.message}")
      end
      for line in e.backtrace
        debug("  #{line}")
      end
    end
    return logger
  end

  def start
    @server = open_server
    @logger.info("started")
    daemon unless @config["debug"]
    @main_thread = Thread.current
    Signal.trap("TERM", &method(:terminate))
    Signal.trap("INT", &method(:terminate))
    begin
      @mail_store = Ximapd::MailStore.new(@config)
      begin
        loop do
          begin
            sock = @server.accept
          rescue Exception => e
            if @config["ssl"] && e.kind_of?(OpenSSL::SSL::SSLError)
              retry
            else
              raise
            end
          end
          unless @config["ssl"]
            sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
            if defined?(Fcntl::FD_CLOEXEC)
              sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) 
            end
            if defined?(Fcntl::O_NONBLOCK)
              sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
            end
          end
          if @sessions.length >= @max_clients
            sock.print("* BYE too many clients\r\n")
            peeraddr = sock.peeraddr[3]
            sock.close
            @logger.info("rejected connection from #{peeraddr}: " +
                         "too many clients")
            next
          end
          Thread.start(sock) do |socket|
            session = Session.new(@config, socket, @mail_store)
            @sessions[Thread.current] = session
            begin
              session.start
            ensure
              @sessions.delete(Thread.current)
            end
          end
        end
      ensure
        @mail_store.close
      end
    rescue SystemExit
      raise
    rescue Exception => e
      @logger.log_exception(e)
    ensure
      @logger.close
      @server.close
    end
  end

  def open_server
    server = TCPServer.new(@config["port"])
    if @config["ssl"]
      require "openssl"
      ssl_ctx = OpenSSL::SSL::SSLContext.new
      if @config.key?("ssl_key") && @config.key?("ssl_cert")
        ssl_ctx.key = File.open(File.expand_path(@config["ssl_key"]), 'r') { |f|
          OpenSSL::PKey::RSA.new(f)
        }
        ssl_ctx.cert = File.open(File.expand_path(@config["ssl_cert"]), 'r') { |f|
          OpenSSL::X509::Certificate.new(f)
        }
      else
        require 'webrick/ssl'
        ssl_ctx.cert, ssl_ctx.key =
          WEBrick::Utils::create_self_signed_cert(1024, [["CN", "Ximapd"]],
                                                  "Generated by Ruby/OpenSSL")
      end
      server = OpenSSL::SSL::SSLServer.new(server, ssl_ctx)
    end
    return server
  end

  def stop
    begin
      open_pid_file("r") do |f|
        pid = f.gets.to_i
        if pid != 0
          Process.kill("TERM", pid)
        end
      end
    rescue Errno::ENOENT
    end
  end

  def version
    printf("ximapd version %s (r%s %s)\n", VERSION, REVISION, DATE)
    puts
    printf("  Platform    : %s\n", RUBY_PLATFORM)
    printf("  Ruby        : %s (%s)\n", RUBY_VERSION, RUBY_RELEASE_DATE)
    begin
      require "openssl"
      printf("  OpenSSL     : %s\n", OpenSSL::VERSION)
    rescue LoadError
      printf("  OpenSSL     : not available\n")
    end
    printf("  ProgressBar : %s\n", ProgressBar::VERSION)
  end

  def help
    puts(@option_parser.help)
  end

  def import
    open_mail_store do |mail_store|
      if @args.empty?
        mail_store.import_file(STDIN, @config["dest_mailbox"])
      else
        mail_store.import(@args, @config["dest_mailbox"])
      end
    end
  end

  def import_mbox
    open_mail_store do |mail_store|
      if @args.empty?
        mail_store.import_mbox_file(STDIN, @config["dest_mailbox"])
      else
        mail_store.import_mbox(@args, @config["dest_mailbox"])
      end
    end
  end

  def import_imap
    unless @config["remote_user"]
      print("user: ")
      @config["remote_user"] = STDIN.gets.chomp
    end
    unless @config["remote_password"]
      print("password: ")
      system("stty", "-echo")
      begin
        @config["remote_password"] = STDIN.gets.chomp
      ensure
        system("stty", "echo")
        puts
      end
    end
    open_mail_store do |mail_store|
      if ARGV.empty?
        args = ["INBOX"]
      else
        args = @args
      end
      mail_store.import_imap(args, @config["dest_mailbox"])
    end
  end

  def rebuild_index
    open_mail_store do |mail_store|
      mail_store.rebuild_index
    end
  end

  def edit_mailbox_db
    open_mail_store do |mail_store|
      system(ENV["EDITOR"] || "vi", mail_store.mailbox_db_path)
    end
  end

  def interactive
    @mail_store = Ximapd::MailStore.new(@config)
    begin
      sock = ConsoleSocket.new
      session = Ximapd::Session.new(@config, sock, @mail_store, true)
      session.start
    ensure
      @mail_store.close
    end
  end

  def check_config(config)
    unless config.key?("data_dir")
      raise "data_dir is not specified"
    end
  end

  def daemon
    exit!(0) if fork
    Process.setsid
    exit!(0) if fork
    open_pid_file("w") do |f|
      f.puts(Process.pid)
    end
    Dir.chdir(File.expand_path(@config["data_dir"]))
    STDIN.reopen("/dev/null")
    STDOUT.reopen("/dev/null", "w")
    path = File.expand_path("stderr", @config["data_dir"])
    STDERR.reopen(path, "a")
  end

  def open_pid_file(mode = "r")
    pid_file = File.expand_path("pid", @config["data_dir"])
    File.open(pid_file, mode) do |f|
      yield(f)
    end
  end

  def close_sessions
    @logger.debug("close #{@sessions.length} sessions")
    i = 1
    @sessions.each_key do |t|
      @logger.debug("close session \##{i}")
      @mail_store.synchronize do
        @logger.debug("raise TerminateException to #{t}")
        t.raise(TerminateException.new)
        @logger.debug("raised TerminateException to #{t}")
      end
      begin
        @logger.debug("join #{t}")
        begin
          t.join
        rescue TerminateException
        end
      rescue SystemExit
        raise
      rescue Exception => e
        @logger.log_exception(e)
      ensure
        @logger.debug("joined #{t}")
      end
      @logger.debug("closed session \##{i}")
      i += 1
    end
  end

  def terminate(sig)
    @logger.info("signal #{sig}")
    @logger.debug("sessions: #{@sessions.keys.inspect}")
    close_sessions
    @logger.info("terminated")
    exit
  end

  def open_mail_store
    mail_store = Ximapd::MailStore.new(@config)
    begin
      mail_store.synchronize do
        if @config["dest_mailbox"] &&
          !mail_store.mailboxes.include?(@config["dest_mailbox"])
          mail_store.create_mailbox(@config["dest_mailbox"])
        end
        yield(mail_store)
      end
    ensure
      mail_store.close
    end
  end

  class TerminateException < Exception; end
  class MailboxError < StandardError; end
  class MailboxExistError < MailboxError; end
  class NoMailboxError < MailboxError; end
  class MailboxAccessError < MailboxError; end
  class NotSelectableMailboxError < MailboxError; end
  class InvalidQueryError < StandardError; end

  class Plugin
    @@directories = nil
    @@loaded = false

    def self.directories=(dirs)
      @@directories = dirs
    end

    def self.create_plugins(config, mail_store)
      return [] unless config.key?("plugins")
      if !@@loaded && @@directories
        logger = config["logger"]
        for plugin in config["plugins"]
          basename = plugin["name"].downcase + ".rb"
          filename = @@directories.collect { |dir|
            File.expand_path(basename, dir)
          }.detect { |filename| File.exist?(filename) }
          raise "#{basename} not found" unless filename
          File.open(filename) do |f|
            Ximapd.class_eval(f.read)
          end
          logger.debug("loaded plugin: #{filename}")
        end
        @@loaded = true
      end
      return config["plugins"].collect { |plugin|
        Ximapd.const_get(plugin["name"]).new(plugin, mail_store,
                                             config["logger"])
      }
    end

    def initialize(config, mail_store, logger)
      @config = config
      @mail_store = mail_store
      @logger = logger
      init_plugin
    end

    def init_plugin
    end

    def filter(mail)
      return nil
    end

    def on_copy(src_mail, dest_mailbox)
    end

    def on_copied(src_mail, dest_mail)
    end

    def on_delete_mail(mail)
    end

    def on_idle
    end
  end

  class ConsoleSocket
    [:read, :gets, :getc].each do |mid|
      define_method(mid) do |*args|
        STDIN.send(mid, *args)
      end
    end

    [:write, :print].each do |mid|
      define_method(mid) do |*args|
        STDOUT.send(mid, *args)
      end
    end

    def peeraddr
      return ["AF_TTY", 0, "tty", "tty"]
    end

    def shutdown
    end

    def close
      STDIN.close
      STDOUT.close
    end

    def fcntl(cmd, arg)
    end
  end

  class NullObject
    def initialize(*args)
    end

    def method_missing(mid, *args)
      return self
    end

    def self.method_missing(mid, *args)
      return new
    end
  end

  begin
    require "progressbar"
  rescue LoadError
    class ProgressBar < NullObject
      VERSION = "not available"
    end
  end

  class Option
    def initialize(*args)
      case args.length
      when 2
        @name, @description = *args
        @arg_name = nil
      when 3
        @name, @arg_name, @description = *args
      else
        raise ArgumentError.new("wrong # of arguments (#{args.length} for 2)")
      end
    end

    def opt_name
      return @name.tr("_", "-")
    end

    def arg_name
      if @arg_name.nil?
        @arg_name = @name.slice(/[a-z]*\z/ni).upcase
      end
      return @arg_name
    end
  end

  class BoolOption < Option
    def define(opts, config)
      opt = "--[no-]" + opt_name
      opts.define(opt, @description) do |arg|
        config[@name] = arg
      end
    end
  end

  class IntOption < Option
    def define(opts, config)
      opt = "--" + opt_name + "=" + arg_name
      opts.define(opt, Integer, @description) do |arg|
        config[@name] = arg
      end
    end
  end

  class StringOption < Option
    def define(opts, config)
      opt = "--" + opt_name + "=" + arg_name
      opts.define(opt, @description) do |arg|
        config[@name] = arg
      end
    end
  end

  class ArrayOption < Option
    def define(opts, config)
      s = arg_name[0, 1]
      args = ("1".."3").collect { |i| s + i.to_s }.join(",")
      opt = "--" + opt_name + "=" + args
      opts.define(opt, Array, @description) do |arg|
        config[@name] = arg
      end
    end
  end

  class Action < Option
    def define(opts, config)
      opt = "--" + opt_name
      opts.define(opt, @description) do
        config["action"] = @name
      end
    end
  end

  OPTIONS = [
    StringOption.new("config_file", "path to .ximapd"),
    IntOption.new("port", "port"),
    StringOption.new("user", "user"),
    StringOption.new("password", "password"),
    StringOption.new("data_dir", "data directory"),
    StringOption.new("plugin_path", "path for plugins"),
    StringOption.new("db_type", "database type (yaml, pstore)"),
    IntOption.new("max_clients", "max number of clients"),
    BoolOption.new("ssl", "use SSL"),
    StringOption.new("ssl_key", "path to SSL private key"),
    StringOption.new("ssl_cert", "path to SSL certificate"),
    BoolOption.new("starttls", "use STARTTLS"),
    BoolOption.new("require_secure", "require secure session for clients"),
    StringOption.new("remote_host", "host of remote IMAP server"),
    IntOption.new("remote_port", "port of remote IMAP server"),
    BoolOption.new("remote_ssl", "use SSL for remote IMAP server"),
    StringOption.new("remote_auth", "auth type of remote IMAP server"),
    StringOption.new("remote_user", "user of remote IMAP server"),
    StringOption.new("remote_password", "password of remote IMAP server"),
    StringOption.new("exclude", "PAT", "exclude files that match PAT"),
    BoolOption.new("import_all", "import all mails by --import-imap"),
    BoolOption.new("import_imap_flags", "import IMAP flags by --import-imap"),
    BoolOption.new("keep", "keep retrieved mails on the remote server"),
    StringOption.new("dest_mailbox", "destination mailbox name"),
    ArrayOption.new("ml_header_fields",
                    "header fields to handle same as X-ML-Name"),
    BoolOption.new("delete_ml_mailboxes", "delete ml mailboxes before rebuild"),
    StringOption.new("default_charset", "default value for charset"),
    StringOption.new("log_level",
                     "log level (fatal, error, warn, info, debug)"),
    IntOption.new("log_shift_age", "number of old log files to keep"),
    IntOption.new("log_shift_size", "max logfile size"),
    IntOption.new("sync_threshold_chars",
                  "number of characters to start index sync"),
    BoolOption.new("debug", "turn on debug mode"),
    BoolOption.new("profile", "turn on profile mode"),
    StringOption.new("profiler_clock_mode", "profiler clock mode"),
    BoolOption.new("verbose", "turn on verbose mode"),
    BoolOption.new("progress", "show progress"),
    StringOption.new("backend",
                     "search backend (Rast, HyperEstraier)"),
  ]

  ACTIONS = [
    Action.new("start", "start daemon"),
    Action.new("stop", "stop daemon"),
    Action.new("import", "import mail"),
    Action.new("import_mbox", "import mbox"),
    Action.new("import_imap", "import from another imap server"),
    Action.new("rebuild_index", "rebuild index"),
    Action.new("edit_mailbox_db", "edit mailbox.db"),
    Action.new("interactive", "interactive mode"),
    Action.new("version", "print version"),
    Action.new("help", "print this message"),
  ]
end

# vim: set filetype=ruby expandtab sw=2 :
