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
require "ximapd/index"

begin
  require "rast"
rescue LoadError
end
begin
  require "HyperEstraier"
rescue LoadError
end

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

if defined?(::Rast)
  module Rast
    unless defined?(RESULT_ALL_ITEMS)
      if Rast::VERSION < "0.1.0"
        RESULT_ALL_ITEMS = 0
      else
        RESULT_ALL_ITEMS = -1
      end
    end
    if Rast::VERSION < "0.1.0"
      RESULT_MIN_ITEMS = 1
    else
      RESULT_MIN_ITEMS = 0
    end
  end
end # if defined?(::Rast)

if defined?(::HyperEstraier)
  module HyperEstraier
    class DatabaseWrapper
      class Error < RuntimeError; end

      private
      def initialize()
        @db = Database.new()
      end

      public
      def open(*args)
        unless @db.open(*args)
          raise Error, "could not open index: #{error_message}"
        end
        yield(self) if block_given?
        nil
      end

      def close
        @db.close
      end

      def put_doc(doc, opt = 0)
        unless @db.put_doc(doc, opt)
          raise Error, "could not put documennt: #{error_message}"
        end
        doc.id
      end

      def out_doc(doc_id, opt = 0)
        unless @db.out_doc(doc_id, opt)
          raise Error, "could not out documennt: #{error_message}"
        end
      end

      def edit_doc(doc)
        unless @db.edit_doc(doc)
          raise Error, "could not edit documment: #{error_message}"
        end
      end

      def get_doc(doc_id, opt = 0)
        begin
          @db.get_doc(doc_id, opt)
        rescue
          nil
        end
      end

      def search(*args)
        @db.search(*args)
      end

      def error
        error = nil
        begin
          error = @db.error
        rescue IOError
        end

        error
      end

      def error_message
        errno = error
        if errno
          HyperEstraier.err_msg(errno)
        else
          '(unknown error)'
        end
      end
    end
  end
end # if defined?(::HyperEstraier)

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
    INDEX_ENGINES.each_pair do |name, info|
      printf("  %-11s : %s\n", name, info[2])
    end
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

  if defined?(::Rast)
    class RastIndex < AbstractIndex
      INDEX_OPTIONS = {
        "encoding" => "utf8",
        "preserve_text" => false,
        "properties" => [
          {
            "name" => "uid",
            "type" => Rast::PROPERTY_TYPE_UINT,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => true,
          },
          {
            "name" => "size",
            "type" => Rast::PROPERTY_TYPE_UINT,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "internal-date",
            "type" => Rast::PROPERTY_TYPE_DATE,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "flags",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "mailbox-id",
            "type" => Rast::PROPERTY_TYPE_UINT,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "date",
            "type" => Rast::PROPERTY_TYPE_DATE,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "subject",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => true,
            "unique" => false,
          },
          {
            "name" => "from",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "to",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "cc",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "bcc",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => false,
            "text_search" => true,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "x-ml-name",
            "type" => Rast::PROPERTY_TYPE_STRING,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          },
          {
            "name" => "x-mail-count",
            "type" => Rast::PROPERTY_TYPE_UINT,
            "search" => true,
            "text_search" => false,
            "full_text_search" => false,
            "unique" => false,
          }
        ]
      }
      DEFAULT_SYNC_THRESHOLD_CHARS = 500000

      module QueryFormat
        module_function

        def quote_query(s)
          return format('"%s"', s.gsub(/[\\"]/n, "\\\\\\&"))
        end
      end

      private

      extend QueryFormat
      class << self

        def make_list_query(list_name)
          {"main" => format("x-ml-name = %s",
                            quote_query(list_name)),
           "sub" => nil}
        end
        public :make_list_query

        def make_default_query(mailbox_id)
          {"main" => format('mailbox-id = %d', mailbox_id), "sub" => nil}
        end
        public :make_default_query

        def make_query(mailbox_name)
          {"main" => mailbox_name, "sub" => nil}
        end
        public :make_query
      end

      def initialize(mail_store)
        super(mail_store)
        @flags_db_path = File.expand_path("flags.sdbm", @path)
        @flags_db = nil
      end

      def setup
        unless File.exist?(@index_path)
          Rast::DB.create(@index_path, INDEX_OPTIONS)
        end
      end
      public :setup

      def standby
        @flags_db = SDBM.open(@flags_db_path)
      end
      public :standby

      def relax
         @flags_db.close
         @flags_db = nil
      end
      public :relax

      def open(*args)
        if args.empty?
          flags = Rast::DB::RDWR
        else
          flags = args.last
        end
        @index = Rast::DB.open(@index_path, flags,
                               "sync_threshold_chars" => @config["sync_threshold_chars"] || DEFAULT_SYNC_THRESHOLD_CHARS)
      end
      public :open

      def close
        @index.close
      end
      public :close

      def register(mail_data, filename)
        doc_id = @index.register(mail_data.text, mail_data.properties)
        set_flags(mail_data.uid, doc_id, nil, mail_data.flags)
      end
      public :register

      def get_flags(uid, item_id, item_obj)
        @flags_db[uid.to_s]
      end
      public :get_flags

      def set_flags(uid, item_id, item_obj, flags)
        @flags_db[uid.to_s] = flags
      end
      public :set_flags

      def delete_flags(uid, item_id, item_obj)
        @flags_db.delete(uid.to_s)
      end
      public :delete_flags

      def delete(uid, item_id)
        @index.delete(item_id)
      end
      public :delete

      def fetch(mailbox, sequence_set)
        result = @index.search(mailbox["query"]["main"],
                               "properties" => ["uid", "internal-date"],
                               "start_no" => 0,
                               "num_items" => Rast::RESULT_ALL_ITEMS,
                               "sort_method" => Rast::SORT_METHOD_PROPERTY,
                               "sort_property" => "uid",
                               "sort_order" => Rast::SORT_ORDER_ASCENDING)
        mails = []
        sequence_set.each do |seq_number|
          case seq_number
          when Range
            first = seq_number.first
            last = seq_number.last == -1 ? result.items.length : seq_number.last
            for i in first .. last
              item = result.items[i - 1]
              mail = IndexedMail.new(@config, mailbox, i, item.properties[0],
                                      item.doc_id, item.properties[1])
              mails.push(mail)
            end
          else
            item = result.items[seq_number - 1]
            next if item.nil?
            mail = IndexedMail.new(@config, mailbox, seq_number,
                                    item.properties[0], item.doc_id,
                                    item.properties[1])
            mails.push(mail)
          end
        end
        return mails
      end
      public :fetch

      def uid_fetch(mailbox, sequence_set)
        options = {
          "properties" => ["uid", "internal-date"],
          "start_no" => 0,
          "num_items" => Rast::RESULT_ALL_ITEMS,
          "sort_method" => Rast::SORT_METHOD_PROPERTY,
          "sort_property" => "uid",
          "sort_order" => Rast::SORT_ORDER_ASCENDING
        }
        additional_queries = sequence_set.collect { |seq_number|
          case seq_number
          when Range
            q = ""
            if seq_number.first > 1
              q += format(" uid >= %d", seq_number.first)
            end
            if seq_number.last != -1
              q += format(" uid <= %d", seq_number.last)
            end
            q
          else
            format("uid = %d", seq_number)
          end
        }.reject { |q| q.empty? }
        if additional_queries.empty?
          query = mailbox["query"]["main"]
        else
          query = mailbox["query"]["main"] +
            " ( " + additional_queries.join(" | ") + " )"
        end
        result = @index.search(query, options)
        return result.items.collect { |i|
          uid = i.properties[0]
          IndexedMail.new(@config, mailbox, uid, uid, i.doc_id, i.properties[1])
        }
      end
      public :uid_fetch

      def mailbox_status(mailbox)
        mailbox_status = MailboxStatus.new

        result = @index.search(mailbox["query"]["main"],
                               "properties" => ["uid"],
                               "start_no" => 0)
        mailbox_status.messages = result.hit_count
        mailbox_status.unseen = result.items.select { |i|
          !/\\Seen\b/ni.match(get_flags(i.properties[0].to_s, nil, nil))
        }.length
        query = format("%s uid > %d",
                        mailbox["query"]["main"], mailbox["last_peeked_uid"])
        result = @index.search(query,
                               "properties" => ["uid"],
                               "start_no" => 0,
                               "num_items" => Rast::RESULT_MIN_ITEMS)
        mailbox_status.recent = result.hit_count

        mailbox_status
      end
      public :mailbox_status

      # returns Rast::Result#items.to_a
      def query(mailbox, query)
      end
      public :query

      def uid_search(mailbox, query)
        options = {
          "properties" => ["uid"],
          "start_no" => 0,
          "num_items" => Rast::RESULT_ALL_ITEMS,
          "sort_method" => Rast::SORT_METHOD_PROPERTY,
          "sort_property" => "uid",
          "sort_order" => Rast::SORT_ORDER_ASCENDING
        }
        q = query["main"] + " " + mailbox["query"]["main"]
        result = @index.search(q, options)
        return result.items.collect { |i| i.properties[0] }
      end
      public :uid_search

      def uid_search_by_keys(mailbox, keys)
        query = keys.collect { |key| key.to_query["main"] }.reject { |q|
          q.empty?
        }.join(" ")
        query = "uid > 0 " + query if /\A\s*!/ =~ query
        uids = uid_search(mailbox, {"main" => query, "sub" => nil})
        for key in keys
          uids = key.select(uids)
        end
        uids
      end
      public :uid_search_by_keys

      def rebuild_index(*args)
        if args.empty?
          flags = Rast::DB::RDWR
        else
          flags = args.last
        end
        old_index_path = @index_path + ".old"

        @old_index = nil
        begin
          File.rename(@index_path, old_index_path)
          @old_index = Rast::DB.open(old_index_path, flags,
                                     "sync_threshold_chars" => @config["sync_threshold_chars"] || DEFAULT_SYNC_THRESHOLD_CHARS)
        rescue Errno::ENOENT
        end
        begin
          @index = Rast::DB.create(@index_path, INDEX_OPTIONS)
          yield
          FileUtils.rm_rf(old_index_path)
        ensure
          @old_index = nil
        end
      end
      public :rebuild_index

      def get_old_flags(uid)
        if @old_index
          @flags_db[uid.to_s]
        else
          nil
        end
      end
      public :get_old_flags

      def try_query(query)
        @index.search(query["main"], "num_items" => Rast::RESULT_MIN_ITEMS)
      end
      public :try_query

      class NullSearchKey
        def to_query
          return {"main" => "", "sub" => nil}
        end

        def select(uids)
          return uids
        end

        def reject(uids)
          return uids
        end
      end

      class BodySearchKey < NullSearchKey
        def initialize(value)
          @value = value
        end

        def to_query
          return {"main" => @value, "sub" => nil}
        end
      end

      class HeaderSearchKey < NullSearchKey
        include QueryFormat

        def initialize(name, value)
          @name = name
          @value = value
        end

        def to_query
          case @name
          when "subject", "from", "to", "cc", "bcc"
            return {"main" => format("%s : %s", @name, quote_query(@value)),
                    "sub" => nil}
          when "x-ml-name", "x-mail-count"
            return {"main" => format("%s = %s", @name, quote_query(@value)),
                    "sub" => nil}
          else
            super
          end
        end
      end

      class FlagSearchKey < NullSearchKey
        def initialize(mail_store, flag)
          @mail_store = mail_store
          @flag_re = Regexp.new(Regexp.quote(flag) + "\\b", true, "n")
        end

        def select(uids)
          @mail_store.open_index do |index|
            return uids.select { |uid|
              @flag_re.match(index.get_flags(uid, nil, nil))
            }
          end
        end

        def reject(uids)
          @mail_store.open_index do |index|
            return uids.reject { |uid|
              @flag_re.match(index.get_flags(uid, nil, nil))
            }
          end
        end
      end

      class NoFlagSearchKey < FlagSearchKey
        alias super_select select
        alias super_reject reject
        alias select super_reject
        alias reject super_select
      end

      class KeywordSearchKey < NullSearchKey
        def initialize(mail_store, flag)
          @mail_store = mail_store
          if /\A\w/n.match(flag)
            s = "\\b"
          else
            s = ""
          end
          @flag_re = Regexp.new(s + Regexp.quote(flag) + "\\b", true, "n")
        end

        def select(uids)
          @mail_store.open_index do |index|
            return uids.select { |uid|
              @flag_re.match(index.get_flags(uid, nil, nil))
            }
          end
        end

        def reject(uids)
          @mail_store.open_index do |index|
            return uids.reject { |uid|
              @flag_re.match(index.get_flags(uid, nil, nil))
            }
          end
        end
      end

      class NoKeywordSearchKey < KeywordSearchKey
        alias super_select select
        alias super_reject reject
        alias select super_reject
        alias reject super_select
      end

      class SequenceNumberSearchKey < NullSearchKey
        def initialize(sequence_set)
          @sequence_set = sequence_set
        end

        def to_query
          raise NotImplementedError.new("sequence number search is not implemented")
        end
      end

      class UidSearchKey < NullSearchKey
        def initialize(sequence_set)
          @sequence_set = sequence_set
        end

        def to_query
          if @sequence_set.empty?
            super
          end
          q = "( " + @sequence_set.collect { |i|
            case i
            when Range
              if i.last == -1
                format("uid >= %d", i.first)
              else
                format("%d <= uid <= %d", i.first, i.last)
              end
            else
              format("uid = %d", i)
            end
          }.join(" | ") + " )"
          return {"main" => q, "sub" => nil}
        end
      end

      class NotSearchKey
        def initialize(key)
          @key = key
        end

        def to_query
          q = @key.to_query
          if q["main"].empty?
            return {"main" => "", "sub" => nil}
          else
            return {"main" => format("! ( %s )", q["main"]), "sub" => nil}
          end
        end

        def select(uids)
          return @key.reject(uids)
        end

        def reject(uids)
          return @key.select(uids)
        end
      end

      class DateSearchKey < NullSearchKey
        def to_query
          return {"main" => format("%s %s %s", field, op, @date.strftime()),
                  "sub" => nil}
        end

        private

        def initialize(date_str)
          @date = parse_date(date_str)
          @date.gmtime
        end

        MONTH = {
          "Jan" =>  1, "Feb" =>  2, "Mar" =>  3, "Apr" =>  4,
          "May" =>  5, "Jun" =>  6, "Jul" =>  7, "Aug" =>  8,
          "Sep" =>  9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
        }
        def parse_date(date_str)
          if date_str.match(/\A"?(\d{1,2})-(#{MONTH.keys.join("|")})-(\d{4})"?\z/o)
            Time.local($3.to_i, MONTH[$2], $1.to_i)
          else
            raise "invlid date string #{date_str}"
          end
        end

        def date_str(date)
          date.strftime("%Y-%m-%dT%H:%M:%S")
        end
      end

      class BeforeSearchKey < DateSearchKey
        def to_query
          return {"main" => format("internal-date < %s", date_str(@date)),
                  "sub" => nil}
        end
      end

      class OnSearchKey < DateSearchKey
        def to_query
          date_end = @date + 86400
          return {"main" => format("%s <= internal-date < %s",
                                   date_str(@date), date_str(date_end)),
                  "sub" => nil}
        end
      end

      class SinceSearchKey < DateSearchKey
        def to_query
          date = @date + 86400
          return {"main" => format("internal-date >= %s", date_str(date)), "sub" => nil}
        end
      end

      class SentbeforeSearchKey < DateSearchKey
        def to_query
          return {"main" => format("date < %s", date_str(@date)), "sub" => nil}
        end
      end

      class SentonSearchKey < DateSearchKey
        def to_query
          date_end = @date + 86400
          return {"main" => format("%s <= date < %s",
                                   date_str(@date), date_str(date_end)),
                  "sub" => nil}
        end
      end

      class SentsinceSearchKey < DateSearchKey
        def to_query
          date = @date + 86400
          return {"main" => format("date >= %s", date_str(date)), "sub" => nil}
        end
      end

      class LargerSearchKey < NullSearchKey
        def initialize(size_str)
          @size_str = size_str
        end

        def to_query
          return {"main" => format("size > %s", @size_str), "sub" => nil}
        end
      end

      class SmallerSearchKey < LargerSearchKey
        def to_query
          return {"main" => format("size < %s", @size_str), "sub" => nil}
        end
      end

      class OrSearchKey < NullSearchKey
        def initialize(key1, key2)
          @keys = [key1, key2]
        end

        def to_query
          qs = []
          @keys.each do |key|
            q = key.to_query
            if q["main"].empty?
              return ""
            elsif /\A\s*!/ =~ q["main"]
              qs << "uid > 0 " + q["main"]
            else
              qs << q["main"]
            end
          end

          return {"main" => format("( %s )", qs.join(" | ")), "sub" => nil}
        end
      end

      class GroupSearchKey < NullSearchKey
        def initialize(keys)
          @keys = keys
        end

        def to_query
          qs = []
          @keys.each do |key|
            q = key.to_query
            if q["main"].empty?
            elsif /\A\s*!/ =~ q["main"]
              qs << "uid > 0 " + q["main"]
            else
              qs << q["main"]
            end
          end

          return {"main" => format("( %s )", qs.join(" & ")), "sub" => nil}
        end
      end

      class EndGroupSearchKey
      end
    end # class RastIndex
    INDEX_ENGINES["Rast"] = [RastIndex, "rast", Rast::VERSION]
  end # if defined?(::Rast)

  if defined?(::HyperEstraier)
    class EstraierIndex < AbstractIndex
      module QueryFormat
        module_function

        def quote_query(s)
          format('"%s"', query.gsub(/[\\"]/n, "\\\\\\&"))
        end
      end

      private

      extend QueryFormat
      class << self
        def make_list_query(list_name)
          {"main" => "",
            "sub" => [format("x-ml-name STREQ %s", list_name)]}
        end
        public :make_list_query

        def make_default_query(mailbox_id)
          {"main" => "",
            "sub" => [format("mailbox-id NUMEQ %d", mailbox_id)]}
        end
        public :make_default_query

        def make_query(mailbox_name)
          sub_query = []
          query = mailbox_name.gsub(/\(([\)]*)\)/) {
            sub_query << $1.strip
            " "
          }
          {"main" => query.strip, "sub" => sub_query}
        end
        public :make_query
      end

      def initialize(mail_store)
        super(mail_store)
      end

      def setup
        unless File.exist?(@index_path)
          db = HyperEstraier::DatabaseWrapper.new()
          begin
            db.open(@index_path,
                    HyperEstraier::Database::DBWRITER|HyperEstraier::Database::DBCREAT|HyperEstraier::Database::DBPERFNG)
          ensure
            begin
              db.close
            rescue
            end
          end
        end
      end
      public :setup

      def standby
        # noop
      end
      public :standby

      def relax
        # noop
      end
      public :relax

      def open(*args)
        if args.empty?
          flags = HyperEstraier::Database::DBWRITER
        else
          flags = args.last
        end
        @index = HyperEstraier::DatabaseWrapper.new()
        begin
          @index.open(@index_path, flags)
        rescue
          begin
            @index.close
          rescue
          end
          raise
        end
      end
      public :open

      def close
        @index.close
      end
      public :close

      def register(mail_data, filename)
        doc = HyperEstraier::Document.new
        doc.add_attr("@uri", "file://" + File.expand_path(filename))
        doc.add_text(mail_data.text)
        mail_data.properties.each_pair do |name, value|
          case name
          when "size"
            doc.add_attr("@size", value.to_s)
          when "internal-date"
            doc.add_attr("@cdate", value.to_s)
            doc.add_attr("@mdate", value.to_s)
          when "subject"
            doc.add_attr("@title", value.to_s)
          when "date"
            doc.add_attr(name, value.to_s)
          else
            doc.add_attr(name, value.to_s)
          end
        end
        doc.add_attr("flags", mail_data.flags)
        @index.put_doc(doc)
      end
      public :register

      def get_uid(item_id)
        uid = nil
        if doc = @index.get_doc(item_id, 0)
          begin
            uid = doc.attr("uid").to_i
          rescue ArgumentError
            raise "item_id:#{item_id} doesnot have uid"
          end
        end
        uid
      end

      def get_doc(uid, item_id, item_obj)
        get_doc_internal(@index, uid, item_id, item_obj)
      end
      def get_doc_internal(index, uid, item_id, item_obj)
        if item_obj
          doc = item_obj
        elsif item_id
          doc = index.get_doc(item_id, 0)
        elsif uid
          cond = HyperEstraier::Condition.new
          cond.add_attr("uid NUMEQ #{uid}")
          doc_id = index.search(cond, 0)[0]
          doc = index.get_doc(doc_id, 0)
        else
          doc = nil
        end
        unless doc
          raise ArgumentError,
            "no such document (uid = #{uid.inspect}, item_id = #{item_id.inspect}, indexed_data.class = #{indexed_data.class})"
        end
        doc
      end

      def get_flags(uid, item_id, item_obj)
        doc = get_doc(uid, item_id, item_obj)
        begin
          doc.attr("flags").scan(/[^<>\s]+/).join(" ")
        rescue ArgumentError
          ""
        end
      end
      public :get_flags

      def set_flags(uid, item_id, item_obj, flags)
        doc = get_doc(uid, item_id, item_obj)
        doc.add_attr("flags", "<" + flags.strip.split(/\s+/).join("><") + ">")
        @index.edit_doc(doc)
      end
      public :set_flags

      def delete_flags(uid, item_id, item_obj)
        set_flags(uid, item_id, item_obj, "")
      end
      public :delete_flags

      def delete(uid, item_id)
        @index.out_doc(item_id)
      end
      public :delete

      def fetch(mailbox, sequence_set)
        result = query(mailbox, {"main" => "", "sub" => []})
        mails = []
        sequence_set.each do |seq_number|
          case seq_number
          when Range
            first = seq_number.first
            last = seq_number.last == -1 ? result.length : seq_number.last
            for i in first .. last
              item_id = result[i - 1]
              doc = get_doc(nil, item_id, nil)
              mail = IndexedMail.new(@config, mailbox, i,
                                     doc.attr("uid").to_i, doc.id,
                                     doc.attr("@mdate"), doc)
              mails.push(mail)
            end
          else
            begin
              doc_id = result.to_a[seq_number - 1]
            rescue IndexError
              next
            end
            doc = get_doc(nil, doc_id, nil)
            mail = IndexedMail.new(@config, mailbox, seq_number,
                                   doc.attr("uid").to_i, doc.id,
                                   doc.attr("@mdate"), doc)
            mails.push(mail)
          end
        end
        mails
      end
      public :fetch

      def uid_fetch(mailbox, sequence_set)
        if sequence_set.empty?
          return []
        end

        mails = []
        result = []
        sequence_set.collect do |i|
          sq = []
          case i
          when Range
            if i.last == -1
              sq << format("uid NUMGE %d", i.first)
            else
              sq << format("uid NUMGE %d", i.first)
              sq << format("uid NUMLE %d", i.last)
            end
          else
            sq << format("uid NUMEQ %d", i)
          end
          result |= query(mailbox, {"main" => "", "sub" => sq})
        end

        result.each do |item_id|
          doc = get_doc(nil, item_id, nil)
          uid = doc.attr("uid").to_i
          mails << IndexedMail.new(@config, mailbox, uid, uid,
                                   item_id, doc.attr("@mdate"),
                                   doc)
        end

        mails
      end
      public :uid_fetch

      def mailbox_status(mailbox)
        mailbox_status = MailboxStatus.new

        cond = HyperEstraier::Condition.new()
        if mailbox["query"]["main"] && !mailbox["query"]["main"].empty?
          cond.set_phrase(mailbox["query"]["main"])
        end
        if mailbox["query"]["sub"]
          mailbox["query"]["sub"].each { |eq| cond.add_attr(eq) }
        end
        result = @index.search(cond, 0)
        mailbox_status.messages = result.length
        mailbox_status.unseen = result.select { |item_id|
          !/\\Seen\b/ni.match(get_flags(nil, item_id, nil))
        }.length
        cond.add_attr("uid NUMGT %d"% mailbox["last_peeked_uid"])
        result = @index.search(cond, 0)
        mailbox_status.recent = result.length
        mailbox_status
      end
      public :mailbox_status

      def query(mailbox, query)
        cond = HyperEstraier::Condition.new()
        cond.set_order("uid NUMA")

        if mailbox["query"]["main"].empty?
          q = query["main"]
        elsif query["main"].empty?
          q = mailbox["query"]["main"]
        else
          q = query["main"] + " " + mailbox["query"]["main"]
        end
        if q && /\S/ =~ q
          cond.set_phrase(q)
        end

        if query["sub"]
          query["sub"].each { |eq| cond.add_attr(eq) }
        end
        if mailbox["query"]["sub"]
          mailbox["query"]["sub"].each { |eq| cond.add_attr(eq) }
        end
        cond.set_order("uid NUMA")
        cond.set_options(HyperEstraier::Condition::CONDSIMPLE)

        result = @index.search(cond, 0)
        result.to_a
      end
      public :query

      def uid_search(mailbox, query)
        result = query(mailbox, query)
        result.collect { |item_id| get_uid(item_id) }
      end
      public :uid_search

      def query_by_keys(mailbox, keys)
        rest_keys = []
        q = {"main" => "", "sub" => []}
        for key in keys
          if kq = key.to_query
            unless kq["main"].empty?
              q["main"] << " "
              q["main"] << kq["main"]
            end
            q["sub"] |= kq["sub"]
          else
            rest_keys << key
          end
        end

        result = query(mailbox, q)
        for key in rest_keys
          result = key.exec(self, mailbox, result)
        end

        result
      end
      public :query_by_keys

      def uid_search_by_keys(mailbox, keys)
        query_by_keys(mailbox, keys).collect { |item_id| get_uid(item_id) }
      end
      public :uid_search_by_keys

      def rebuild_index(*args)
        if args.empty?
          flags = HyperEstraier::Database::DBWRITER|HyperEstraier::Database::DBCREAT|HyperEstraier::Database::DBPERFNG
        else
          flags = args.last
        end
        old_index_path = @index_path + ".old"

        @old_index = nil
        begin
          File.rename(@index_path, old_index_path)
          @old_index = HyperEstraier::DatabaseWrapper.new()
          begin
            @old_index.open(old_index_path, HyperEstraier::Database::DBREADER)
          rescue
            begin
              @old_index.close
            rescue
            end
            raise
          end
        rescue Errno::ENOENT
        end
        @index = HyperEstraier::DatabaseWrapper.new()
        @index.open(@index_path, flags)
        @index.close
        begin
          yield
          FileUtils.rm_rf(old_index_path)
        ensure
          @old_index = nil
        end
      end
      public :rebuild_index

      def get_old_flags(uid)
        raise RuntimeError, "old index not given" unless @old_index

        doc = get_doc_internal(@old_index, uid, nil, nil)
        begin
          doc.attr("flags")
        rescue ArgumentError
          ""
        end
      end
      public :get_old_flags

      def try_query(query)
        cond = HyperEstraier::Condition.new() 
        cond.set_max(1)
        cond.set_phrase(query["main"])       
        if query["sub"]
          query["sub"].each { |eq| cond.add_attr(eq) }
        end 
        r = @index.search(cond, 0)
        unless r.kind_of?(HyperEstraier::IntVector)
          raise "search failed for #{query["main"].dump} (#{query["sub"].collect { |eq| eq.dump }.join(', ')})"
        end   
        true
      end
      public :try_query

      class AbstractSearchKey
        def to_query
          nil
        end

        def exec
          raise
        end
      end

      class NullSearchKey < AbstractSearchKey
        def to_query
          {"main" => "", "sub" => []}
        end
      end

      class BodySearchKey < AbstractSearchKey
        def initialize(value)
          @value = value
        end

        def to_query
          {"main" => @value, "sub" => []}
        end
      end

      class HeaderSearchKey < AbstractSearchKey
        def initialize(name, value)
          @name = name
          @value = value
        end

        def to_query
          query = nil
          case @name
          when "subject"
            return {"main" => "", 
                    "sub" => [format("@title STRINC %s", @value)]}
          when "from", "to", "cc", "bcc"
            return {"main" => "",
                     "sub" => [format("%s STRINC %s", @name, @value)]}
          when "x-ml-name", "x-mail-count"
            return {"main" => "",
                     "sub" => [format("%s STREQ %s", @name, @value)]}
          else
            return {"main" => "", "sub" => []}
          end
        end
      end

      class FlagSearchKey < AbstractSearchKey
        def initialize(mail_store, flag)
          @mail_store = mail_store
          @flag = "<" + flag + ">"
        end

        def to_query
          return {"main" => "", "sub" => [format("flags STRINC %s", @flag)]}
        end
      end

      class NoFlagSearchKey < FlagSearchKey
        def to_query
          return {"main" => "", "sub" => [format("flags !STRINC %s", @flag)]}
        end
      end

      class KeywordSearchKey < FlagSearchKey
        def to_query
          return {"main" => "", "sub" => [format("flags STRINC %s", @flag)]}
        end
      end

      class NoKeywordSearchKey < FlagSearchKey
        def to_query
          return {"main" => "", "sub" => [format("flags !STRINC %s", @flag)]}
        end
      end

      class SequenceNumberSearchKey < AbstractSearchKey
        def initialize(sequence_set)
          @sequence_set = sequence_set
        end

        def to_query
          raise NotImplementedError.new("sequence number search is not implemented")
        end
        def exec(index, mailbox, result)
          raise NotImplementedError.new("sequence number search is not implemented")
        end
      end

      class UidSearchKey < AbstractSearchKey
        def initialize(sequence_set)
          @sequence_set = sequence_set
        end

        def exec(index, mailbox, result)
          if @sequence_set.empty?
            return result
          end
          sr = []
          @sequence_set.collect { |i|
            sq = []
            case i
            when Range
              if i.last == -1
                sq << format("uid NUMGE %d", i.first)
              else
                sq << format("uid NUMGE %d", i.first)
                sq << format("uid NUMLE %d", i.last)
              end
            else
              sq << format("uid NUMEQ %d", i)
            end
            sr |= index.query(mailbox, {"main" => "", "sub" => sq})
          }
          return result & sr
        end
      end

      class NotSearchKey < AbstractSearchKey
        def initialize(key)
          @key = key
        end

        def exec(index, mailbox, result)
          result - index.query_by_keys(mailbox, [@key])
        end
      end

      class DateSearchKey < NullSearchKey
        def to_query
          return {"main" => format("%s %s %s", field, op, @date.strftime()),
                  "sub" => nil}
        end

        private

        def initialize(date_str)
          @date = parse_date(date_str)
          @date.gmtime
        end

        MONTH = {
          "Jan" =>  1, "Feb" =>  2, "Mar" =>  3, "Apr" =>  4,
          "May" =>  5, "Jun" =>  6, "Jul" =>  7, "Aug" =>  8,
          "Sep" =>  9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
        }
        def parse_date(date_str)
          if date_str.match(/\A"?(\d{1,2})-(#{MONTH.keys.join("|")})-(\d{4})"?\z/o)
            Time.local($3.to_i, MONTH[$2], $1.to_i)
          else
            raise "invlid date string #{date_str}"
          end
        end

        def date_str(date)
          date.strftime("%Y-%m-%dT%H:%M:%S")
        end
      end

      class BeforeSearchKey < DateSearchKey
        def to_query
          return {"main" => "",
                  "sub" => [format("@cdate NUMLT %s", date_str(@date))]}
        end
      end

      class OnSearchKey < DateSearchKey
        def to_query
          date_end = @date + 86400
          return {"main" => "",
                  "sub" => [format("@cdate NUMGE %s", date_str(@date)),
                            format("@cdate NUMLT %s", date_str(date_end))]}
        end
      end

      class SinceSearchKey < DateSearchKey
        def to_query
          date = @date + 86400
          return {"main" => "",
                  "sub" => [format("@cdate NUMGE %s", date_str(date))]}
        end
      end

      class SentbeforeSearchKey < DateSearchKey
        def to_query
          return {"main" => "",
                  "sub" => [format("date NUMLT %s", date_str(@date))]}
        end
      end

      class SentonSearchKey < DateSearchKey
        def to_query
          date_end = @date + 86400
          return {"main" => "",
                  "sub" => [format("date NUMGE %s", date_str(@date)),
                            format("date NUMLT %s", date_str(date_end))]}
        end
      end

      class SentsinceSearchKey < DateSearchKey
        def to_query
          date = @date + 86400
          return {"main" => "",
                  "sub" => [format("date NUMGE %s", date_str(date))]}
        end
      end

      class LargerSearchKey < NullSearchKey
        def initialize(size_str)
          @size_str = size_str
        end

        def to_query
          return {"main" => "", "sub" => [format("@size NUMGT %s", @size_str)]}
        end
      end

      class SmallerSearchKey < LargerSearchKey
        def to_query
          return {"main" => "", "sub" => [format("@size NUMLT %s", @size_str)]}
        end
      end

      class OrSearchKey < AbstractSearchKey
        def initialize(key1, key2)
          @keys = [key1, key2]
        end

        def exec(index, mailbox, result)
          sresult = []
          @keys.each do |key|
            sresult |= index.query_by_keys(mailbox, [key])
          end

          result & sresult
        end
      end

      class GroupSearchKey < AbstractSearchKey
        def initialize(keys)
          @keys = keys
        end

        def exec(index, mailbox, result)
          result & index.query_by_keys(mailbox, @keys)
        end
      end

      class EndGroupSearchKey
      end
    end # class EstraierIndex
    INDEX_ENGINES["Estraier"] = [EstraierIndex, "HyperEstraier", '(unknown)']
  end # if defined?(::HyperEstraier)

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
    StringOption.new("index_engine",
                     "index engine (#{INDEX_ENGINES.keys.join(', ')})"),
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
