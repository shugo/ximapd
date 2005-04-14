#!/usr/bin/env ruby
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
require "net/imap"
require "pstore"
require "yaml/store"
require "find"
require "fileutils"
require "bdb"
require "digest/md5"
require "iconv"
require "nkf"
require "date"
require "logger"
require "tmail"
require "rast"

class Ximapd
  VERSION = "0.0.0"

  @@debug = false

  def self.debug
    return @@debug
  end

  def self.debug=(debug)
    @@debug = debug
  end

  @@verbose = false

  def self.verbose
    return @@verbose
  end

  def self.verbose=(verbose)
    @@verbose = verbose
  end

  def initialize(config)
    check_config(config)
    @config = config
    @server = nil
  end

  def start
    @server = TCPServer.new(@config["port"])
    daemon if !Ximapd.debug
    loop do
      sock = @server.accept
      Thread.start(sock) do |socket|
        service = Session.new(@config, sock)
        service.start
      end
    end
  end

  def stop
    open_pid_file("r") do |f|
      pid = f.gets.to_i
      if pid != 0
        Process.kill("TERM", pid)
      end
    end
  end

  def print_version
    printf("ximapd version %s\n", VERSION)
  end

  private

  def check_config(config)
    unless config.key?("data_dir")
      raise "data_dir is not specified"
    end
  end

  def daemon
    exit! if fork
    Process.setsid
    exit! if fork
    open_pid_file("w") do |f|
      f.puts(Process.pid)
    end
    Dir.chdir("/")
    STDIN.reopen("/dev/null")
    STDOUT.reopen("/dev/null", "w")
    STDERR.reopen("/dev/null", "w")
  end

  def open_pid_file(mode = "r")
    pid_file = File.expand_path("pid", @config["data_dir"])
    File.open(pid_file, mode) do |f|
      yield(f)
    end
  end

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
        "unique" => false,
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

  DEFAULT_HISTORY_SIZE = 10
  DEFAULT_CHARSET = "iso-2022-jp"
  DEFAULT_SYNC_THRESHOLD_CHARS = 500000

  DEFAULT_STATUS = {
    "uidvalidity" => 1,
    "last_uid" => 0,
    "last_mailbox_id" => 1
  }
  DEFAULT_MAILBOXES = {
    "INBOX" => {
      "flags" => "",
      "id" => 1,
      "query" => "mailbox-id = 1",
      "last_peeked_uid" => 0
    },
    "ml" => {
      "flags" => "\\Noselect"
    },
    "history" => {
      "flags" => "\\Noselect"
    },
    "queries" => {
      "flags" => "\\Noselect"
    }
  }

  module QueryFormat
    module_function

    def quote_query(s)
      return format('"%s"', s.gsub(/[\\"]/n, "\\\\\\1"))
    end
  end

  module DataFormat
    module_function

    def quoted(s)
      return format('"%s"', s.gsub(/[\\"]/n, "\\\\\\1"))
    end

    def literal(s)
      return format("{%d}\r\n%s", s.length, s)
    end
  end

  class MailStore
    include QueryFormat

    attr_reader :flags_db

    def initialize(config)
      @config = config
      @path = File.expand_path(@config["data_dir"])
      @mail_path = File.expand_path("mail", @path)
      @db_path = File.expand_path("db", @path)
      begin
        Dir.mkdir(@path)
        Dir.mkdir(@mail_path)
        Dir.mkdir(@db_path)
      rescue Errno::EEXIST
      end
      mailbox_db_path = File.expand_path("mailbox.db", @path)
      case @config["db_type"].to_s.downcase
      when "pstore"
        @mailbox_db = PStore.new(mailbox_db_path)
      else
        @mailbox_db = YAML::Store.new(mailbox_db_path)
      end
      @mailbox_db.transaction do
        @mailbox_db["status"] ||= DEFAULT_STATUS.dup
        @mailbox_db["mailboxes"] ||= DEFAULT_MAILBOXES.dup
        @mailbox_db["mailing-lists"] ||= {}
      end
      @db_env = BDB::Env.new(@db_path,
                             BDB::CREATE | BDB::INIT_MPOOL |
                             BDB::INIT_LOCK | BDB::INIT_LOG)
      @flags_db = BDB::Recno.open("flags.db", nil, BDB::CREATE,
                                  "env" => @db_env)
      @index_path = File.expand_path("index", @path)
      if !File.exist?(@index_path)
        Rast::DB.create(@index_path, INDEX_OPTIONS)
      end
      @default_charset = @config["default_charset"] || DEFAULT_CHARSET
      @history_size = @config["history_size"] || DEFAULT_HISTORY_SIZE
      @sync_threshold_chars =
        @config["sync_threshold_chars"] || DEFAULT_SYNC_THRESHOLD_CHARS
      @last_peeked_uids = {}
    end

    def close
      @mailbox_db.transaction do
        @last_peeked_uids.each do |name, uid|
          @mailbox_db["mailboxes"][name]["last_peeked_uid"] = uid
        end
      end
      @flags_db.close
    end

    def sync
      @flags_db.sync
    end

    def mailboxes
      @mailbox_db.transaction do
        return @mailbox_db["mailboxes"]
      end
    end

    def create_mailbox(name, query = nil)
      @mailbox_db.transaction do
        dir = name.slice(/(.*)\/\z/ni, 1)
        if dir
          mkdir_p(dir)
        else
          mkdir_p(File.dirname(name))
          create_mailbox_internal(name, query)
        end
      end
    end

    def delete_mailbox(name)
      @mailbox_db.transaction do
        pat = "\\A" + Regexp.quote(name) + "(/.*)?\\z"
        re = Regexp.new(pat, nil, "n")
        @mailbox_db["mailboxes"].delete_if do |k, v|
          re.match(k)
        end
      end
    end

    def rename_mailbox(name, new_name)
      @mailbox_db.transaction do
        if @mailbox_db["mailboxes"].include?(new_name)
          raise format("%s already exists", new_name)
        end
        mkdir_p(File.dirname(new_name))
        pat = "\\A" + Regexp.quote(name) + "(/.*)?\\z"
        re = Regexp.new(pat, nil, "n")
        mailboxes = @mailbox_db["mailboxes"].select { |k, v|
          re.match(k)
        }
        for k, v in mailboxes
          new_key = k.sub(re) { $1 ? new_name + $1 : new_name }
          @mailbox_db["mailboxes"].delete(k)
          @mailbox_db["mailboxes"][new_key] = v
        end
      end
    end

    def get_mailbox_status(mailbox_name)
      @mailbox_db.transaction do
        mailboxes = @mailbox_db["mailboxes"]
        mailbox = mailboxes[mailbox_name]
        if mailbox.nil?
          raise NoMailboxError.new("no such mailbox")
        end
        if /\\Noselect/ni.match(mailbox["flags"])
          raise MailboxAccessError.new("can't access mailbox")
        end
        open_index do |index|
          status = MailboxStatus.new
          result = index.search(mailbox["query"],
                                "properties" => ["uid"],
                                "start_no" => 0)
          status.messages = result.hit_count
          status.unseen = result.items.select { |i|
            !/\\Seen\b/ni.match(@flags_db[i.properties[0]])
          }.length
          query = format("%s uid > %d",
                         mailbox["query"], mailbox["last_peeked_uid"])
          result = index.search(query,
                                "properties" => ["uid"],
                                "start_no" => 0,
                                "num_items" => 1)
          status.recent = result.hit_count
          status.uidnext = @mailbox_db["status"]["last_uid"] + 1
          status.uidvalidity = @mailbox_db["status"]["uidvalidity"]
          @last_peeked_uids[mailbox_name] = @mailbox_db["status"]["last_uid"]
          return status
        end
      end
    end

    MailboxStatus = Struct.new(:messages, :recent, :uidnext, :uidvalidity,
                               :unseen)

    def import(args)
      @mailbox_db.transaction do
        open_index do |index|
          for arg in args
            Find.find(arg) do |filename|
              if File.file?(filename)
                open(filename) do |f|
                  uid = import_mail_internal(index, f.read)
                  if Ximapd.verbose
                    printf("imported UID=%d filename=%s\n", uid, filename)
                  end
                end
              end
            end
          end
        end
      end
    end

    def import_file(f)
      return import_mail(f.read)
    end

    def import_mbox(args)
      @mailbox_db.transaction do
        open_index do |index|
          for arg in args
            Find.find(arg) do |filename|
              if File.file?(filename)
                open(filename) do |f|
                  import_mbox_internal(index, f)
                end
              end
            end
          end
        end
      end
    end

    def import_mbox_file(f)
      @mailbox_db.transaction do
        open_index do |index|
          import_mbox_internal(index, f)
        end
      end
    end

    def import_mail(str, mailbox_name = nil, flags = "")
      @mailbox_db.transaction do
        open_index do |index|
          return import_mail_internal(index, str, mailbox_name, flags)
        end
      end
    end

    def uid_search(mailbox_name, query)
      mailbox = get_mailbox(mailbox_name)
      open_index do |index|
        options = {
          "properties" => ["uid"],
          "start_no" => 0,
          "num_items" => 0,
          "sort_method" => Rast::SORT_METHOD_PROPERTY,
          "sort_property" => "uid",
          "sort_order" => Rast::SORT_ORDER_ASCENDING
        }
        #if mailbox_name != "INBOX"
        #  query += " " + mailbox["query"]
        #end
        query += " " + mailbox["query"]
        result = index.search(query, options)
        add_history(query)
        return result.items.collect { |i| i.properties[0] }
      end
    end

    def fetch(mailbox_name, sequence_set)
      mailbox = get_mailbox(mailbox_name)
      open_index do |index|
        result = index.search(mailbox["query"],
                              "properties" => ["uid"],
                              "start_no" => 0,
                              "num_items" => 0,
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
              mail = mailbox.get_mail(i, result.items[i - 1].properties[0])
              mails.push(mail)
            end
          else
            item = result.items[seq_number - 1]
            next if item.nil?
            uid = item.properties[0]
            mail = mailbox.get_mail(seq_number, uid)
            mails.push(mail)
          end
        end
        return mails
      end
    end

    def uid_fetch(mailbox_name, sequence_set)
      mailbox = get_mailbox(mailbox_name)
      open_index do |index|
        options = {
          "properties" => ["uid"],
          "start_no" => 0,
          "num_items" => 0,
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
          query = mailbox["query"]
        else
          query = mailbox["query"] +
            " (" + additional_queries.join(" | ") + ")"
        end
        result = index.search(query, options)
        return result.items.collect { |i|
          uid = i.properties[0]
          mailbox.get_mail(uid, uid)
        }
      end
    end

    def get_mailbox(name)
      @mailbox_db.transaction do
        return Mailbox.new(@config, name,
                           @mailbox_db["mailboxes"][name], @flags_db)
      end
    end

    private

    def open_index(flags = Rast::DB::RDWR)
      index = Rast::DB.open(@index_path, flags,
                            "sync_threshold_chars" => @sync_threshold_chars)
      begin
        yield(index)
      ensure
        index.close
      end
    end

    def mkdir_p(dirname)
      if /\A\//n.match(dirname)
        raise "can't specify absolute path"
      end
      if dirname == "." ||
        @mailbox_db["mailboxes"].include?(dirname)
        return
      end
      mkdir_p(File.dirname(dirname))
      @mailbox_db["mailboxes"][dirname] = {
        "flags" => "\\Noselect"
      }
    end

    def create_mailbox_internal(name, query = nil)
      if @mailbox_db["mailboxes"].key?(name)
        raise MailboxExistError, format("mailbox already exist - %s", name)
      end
      mailbox = {
        "flags" => "",
        "last_peeked_uid" => 0
      }
      if query.nil?
        s = name.slice(/\Aqueries\/(.*)/, 1)
        if s.nil?
          @mailbox_db["status"]["last_mailbox_id"] += 1
          query = format('mailbox-id = %d',
                         @mailbox_db["status"]["last_mailbox_id"])
          mailbox["id"] = @mailbox_db["status"]["last_mailbox_id"]
        else
          query = Net::IMAP.decode_utf7(s)
        end
      end
      mailbox["query"] = query
      @mailbox_db["mailboxes"][name] = mailbox
    end

    def import_mbox_internal(index, f)
      s = nil
      f.each_line do |line|
        if /\AFrom /.match(line)
          if s
            uid = import_mail_internal(index, s)
            printf("imported UID=%d\n", uid) if Ximapd.verbose
          end
          s = line
        else
          s.concat(line) if s
        end
      end
      if s
        uid = import_mail_internal(index, s)
        printf("imported UID=%d\n", uid) if Ximapd.verbose
      end
    end

    def import_mail_internal(index, str, mailbox_name = nil, flags = "")
      if mailbox_name.nil?
        mailbox_id = 0
      else
        mailbox = @mailbox_db["mailboxes"][mailbox_name]
        if mailbox.nil?
          raise NoMailboxError.new("no such mailbox")
        end
        mailbox_id = mailbox["id"]
        if mailbox_id.nil?
          raise MailboxAccessError.new("can't import to virtual mailbox")
        end
      end
      s = str.gsub(/\r?\n/, "\r\n").sub(/\AFrom .*\r\n/, "")
      @mailbox_db["status"]["last_uid"] += 1
      uid = @mailbox_db["status"]["last_uid"]
      path = get_mail_path(uid)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        f.flock(File::LOCK_EX)
        f.print(s)
      end
      @flags_db[uid] = flags
      index_mail(index, uid, s, mailbox_id)
      return uid
    end

    def get_mail_path(uid)
      dir1, dir2 = *[uid].pack("v").unpack("H2H2")
      relpath = format("%s/%s/%d", dir1, dir2, uid)
      return File.expand_path(relpath, @mail_path)
    end

    def index_mail(index, uid, mail, mailbox_id)
      properties = Hash.new("")
      properties["uid"] = uid
      properties["size"] = mail.size
      properties["flags"] = ""
      properties["internal-date"] = DateTime.now.to_s
      properties["date"] = properties["internal-date"]
      properties["x-mail-count"] = 0
      properties["mailbox-id"] = mailbox_id
      begin
        m = TMail::Mail.parse(mail)
        text = extract_text(m)
        properties = extract_properties(m, properties)
      rescue
        header, body = *mail.split(/^\r\n/)
        text = to_utf8(body, @default_charset)
      end
      index.register(text, properties)
      s = properties["x-ml-name"]
      if !s.empty? && !@mailbox_db["mailing-lists"].key?(s)
        mbox = s.slice(/(.*) <.*>/u, 1) 
        if mbox.nil?
          mbox = s.slice(/<(.*)>/u, 1) 
          if mbox.nil?
            mbox = s.slice(/\S+@[^ \t;]+/u) 
            if mbox.nil?
              mbox = s
            end
          end
        end
        @mailbox_db["mailing-lists"][s] = uid
        mailbox_name = format("ml/%s", Net::IMAP.encode_utf7(mbox))
        query = format("x-ml-name = %s", quote_query(properties["x-ml-name"]))
        begin
          create_mailbox_internal(mailbox_name, query)
        rescue MailboxExistError
        end
      end
    end

    def extract_text(mail)
      if mail.multipart?
        return mail.parts.collect { |part|
          extract_text(part)
        }.join("\n")
      else
        case mail.content_type("text/plain")
        when "text/plain"
          return get_body(mail)
        when "text/html", "text/xml"
          return get_body(mail).gsub(/<.*?>/um, "")
        else
          return ""
        end
      end
    end

    def get_body(mail)
      charset = mail.type_param("charset", @default_charset)
      return to_utf8(mail.body, charset)
    end

    def to_utf8(src, charset)
      begin
        return Iconv.conv("utf-8", charset, src)
      rescue
        return NKF.nkf("-m0 -w", src)
      end
    end

    def extract_properties(mail, properties)
      for field in ["subject", "from", "to", "cc"]
        properties[field] = get_header_field(mail, field)
      end
      begin
        properties["date"] = DateTime.parse(mail["date"].to_s).to_s
      rescue
      end
      s = (mail["x-ml-name"] || mail["list-id"] || mail["mailing-list"]).to_s
      properties["x-ml-name"] = NKF.nkf("-m0 -w", s)
      properties["x-mail-count"] = mail["x-mail-count"].to_s.to_i
      if properties["mailbox-id"] == 0 && properties["x-ml-name"].empty?
        properties["mailbox-id"] = 1
      end
      return properties
    end

    def get_header_field(mail, field)
      return NKF.nkf("-m0 -w", mail[field].to_s)
    end

    def add_history(query)
      @mailbox_db.transaction do
        histories = @mailbox_db["mailboxes"].keys.grep(/\Ahistory\//).sort
        if histories.length >= @history_size
          histories[0, histories.length - @history_size + 1].each do |mbox|
            @mailbox_db["mailboxes"].delete(mbox)
          end
        end
        history_name = format("history/%s",
                              DateTime.now.strftime("%Y-%m-%d %H:%M:%S"))
        n = 2
        begin
          create_mailbox_internal(history_name, query)
        rescue MailboxExistError
          s = format("<%d>", n)
          if n == 2
            history_name += " " + s
          else
            history_name.sub!(/<.*?>\z/n, s)
          end
          n += 1
          retry
        end
      end
    end
  end

  class Mailbox
    attr_reader :name, :flags_db

    def initialize(config, name, data, flags_db)
      @config = config
      @name = name
      @data = data
      @flags_db = flags_db
    end

    def [](key)
      return @data[key]
    end

    def get_mail(seqno, uid)
      return Mail.new(@config, self, seqno, uid, @flags_db)
    end
  end

  class Mail
    include DataFormat

    attr_reader :mailbox, :seqno, :uid

    def initialize(config, mailbox, seqno, uid, flags_db)
      @config = config
      @mailbox = mailbox
      @seqno = seqno
      @uid = uid
      @flags_db = flags_db
    end

    def flags(get_recent = true)
      s = @flags_db[@uid].to_s
      if get_recent && uid > @mailbox["last_peeked_uid"]
        if s.empty?
          return "\\Recent"
        else
          return "\\Recent " + s
        end
      else
        return s
      end
    end

    def flags=(s)
      @flags_db[@uid] = s
    end

    def path
      dir1, dir2 = *[@uid].pack("v").unpack("H2H2")
      relpath = format("mail/%s/%s/%d", dir1, dir2, uid)
      return File.expand_path(relpath, @config["data_dir"])
    end

    def size
      return File.size(path)
    end

    def to_s
      open(path) do |f|
        f.flock(File::LOCK_SH)
        return f.read
      end
    end

    def header
      open(path) do |f|
        f.flock(File::LOCK_SH)
        return f.gets("\r\n\r\n")
      end
    end

    def header_fields(fields)
      pat = "^(?:" + fields.collect { |field|
        Regexp.quote(field)
      }.join("|") + "):.*(?:\r\n[ \t]+.*)*\r\n"
      re = Regexp.new(pat, true, "n")
      return header.scan(re).join + "\r\n"
    end

    def body
      mail = TMail::Mail.parse(to_s)
      return body_internal(mail)
    end

    private

    def body_internal(mail)
      if mail.multipart?
        parts = mail.parts.collect { |part|
          body_internal(part)
        }.join
        return format("(%s %s)", parts, quoted(mail.sub_type.upcase))
      else
        fields = []
        content_type = mail["content-type"]
        if content_type.nil?
          params = "()"
        else
          params = "(" + content_type.params.collect { |k, v|
            format("%s %s", quoted(k.upcase), quoted(v.upcase))
          }.join(" ") + ")"
        end
        fields.push(params)
        fields.push("NIL")
        fields.push("NIL")
        content_transfer_encoding =
          (mail["content-transfer-encoding"] || "7BIT").to_s.upcase
        fields.push(quoted(content_transfer_encoding))
        fields.push(mail.body.length.to_s)
        if mail.main_type == "text"
          fields.push(mail.body.to_a.length.to_s)
        end
        return format("(%s %s %s)",
                      quoted(mail.main_type.upcase),
                      quoted(mail.sub_type.upcase),
                      fields.join(" "))
      end
    end
  end

  NON_AUTHENTICATED_STATE = :NON_AUTHENTICATED_STATE
  AUTHENTICATED_STATE = :AUTHENTICATED_STATE
  SELECTED_STATE = :SELECTED_STATE
  LOGOUT_STATE = :LOGOUT_STATE

  class Session
    attr_reader :config, :state, :mail_store, :current_mailbox

    @@test = false

    def self.test
      return @@test
    end

    def self.test=(test)
      @@test = test
    end

    def initialize(config, sock)
      @config = config
      @sock = sock
      @parser = CommandParser.new(self)
      @logout = false
      @peeraddr = nil
      @state = NON_AUTHENTICATED_STATE
      @mail_store = nil
      @current_mailbox = nil
    end

    def start
      @peeraddr = @sock.peeraddr
      send_ok("ximapd version %s", VERSION)
      while !@logout
        begin
          cmd = recv_cmd
        rescue
          send_bad("parse error: %s", $!)
          next
        end
        break if cmd.nil?
        begin
          cmd.exec
        rescue
          raise if @@test
          send_tagged_bad(cmd.tag, "%s failed - %s", cmd.name, $!)
          if Ximapd.debug
            STDERR.printf("%s: %s\n", $!.class, $!)
            for line in $@
              STDERR.printf("  %s\n", line)
            end
          end
        end
      end
      @mail_store.close if @mail_store
      @sock.shutdown
      @sock.close
    end

    def logout
      @state = LOGOUT_STATE
      @logout = true
    end

    def login
      @mail_store = MailStore.new(@config)
      @state = AUTHENTICATED_STATE
    end

    def select(mailbox)
      @current_mailbox = mailbox
      @state = SELECTED_STATE
    end

    def close_mailbox
      @current_mailbox = nil
      @state = AUTHENTICATED_STATE
    end

    def sync
      @mail_store.sync if @mail_store
    end

    def recv_line
      s = @sock.gets("\r\n")
      return s if s.nil?
      line = s.sub(/\r\n\z/n, "")
      if Ximapd.debug
        $stderr.puts(line.gsub(/^/n, "C: "))
      end
      return line
    end

    def recv_cmd
      buf = ""
      loop do
        s = @sock.gets("\r\n")
        break unless s
        buf.concat(s)
        if /\{(\d+)\}\r\n/n =~ s
          send_continue_req("Ready for additional command text")
          s = @sock.read($1.to_i)
          buf.concat(s)
        else
          break
        end
      end
      return nil if buf.length == 0
      if Ximapd.debug
        $stderr.print(buf.gsub(/^/n, "C: "))
      end
      return @parser.parse(buf)
    end

    def send_line(line)
      if Ximapd.debug
        $stderr.puts(line.gsub(/^/n, "S: "))
      end
      @sock.print(line + "\r\n")
    end

    def send_tagged_response(tag, name, fmt, *args)
      msg = format(fmt, *args)
      send_line(tag + " " + name + " " + msg)
    end

    def send_tagged_ok(tag, fmt, *args)
      send_tagged_response(tag, "OK", fmt, *args)
    end

    def send_tagged_no(tag, fmt, *args)
      send_tagged_response(tag, "NO", fmt, *args)
    end

    def send_tagged_bad(tag, fmt, *args)
      send_tagged_response(tag, "BAD", fmt, *args)
    end

    def send_data(fmt, *args)
      s = format(fmt, *args)
      send_line("* " + s)
    end

    def send_ok(fmt, *args)
      send_data("OK " + fmt, *args)
    end

    def send_no(fmt, *args)
      send_data("NO " + fmt, *args)
    end

    def send_bad(fmt, *args)
      send_data("BAD " + fmt, *args)
    end

    def send_continue_req(fmt, *args)
      msg = format(fmt, *args)
      send_line("+ " + msg)
    end
  end

  class CommandParser
    def initialize(session)
      @session = session
      @str = nil
      @pos = nil
      @lex_state = nil
      @token = nil
    end

    def parse(str)
      @str = str
      @pos = 0
      @lex_state = EXPR_BEG
      @token = nil
      return command
    end

    private

    EXPR_BEG          = :EXPR_BEG
    EXPR_DATA         = :EXPR_DATA
    EXPR_TEXT         = :EXPR_TEXT
    EXPR_RTEXT        = :EXPR_RTEXT
    EXPR_CTEXT        = :EXPR_CTEXT

    T_SPACE   = :SPACE
    T_NIL     = :NIL
    T_NUMBER  = :NUMBER
    T_ATOM    = :ATOM
    T_QUOTED  = :QUOTED
    T_LPAR    = :LPAR
    T_RPAR    = :RPAR
    T_BSLASH  = :BSLASH
    T_STAR    = :STAR
    T_LBRA    = :LBRA
    T_RBRA    = :RBRA
    T_LITERAL = :LITERAL
    T_PLUS    = :PLUS
    T_PERCENT = :PERCENT
    T_CRLF    = :CRLF
    T_EOF     = :EOF
    T_TEXT    = :TEXT

    BEG_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 3:  NUMBER  )(\d+)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 4:  ATOM    )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+]+)|\
(?# 5:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\))|\
(?# 8:  BSLASH  )(\\)|\
(?# 9:  STAR    )(\*)|\
(?# 10: LBRA    )(\[)|\
(?# 11: RBRA    )(\])|\
(?# 12: LITERAL )\{(\d+)\}\r\n|\
(?# 13: PLUS    )(\+)|\
(?# 14: PERCENT )(%)|\
(?# 15: CRLF    )(\r\n)|\
(?# 16: EOF     )(\z))/ni

    DATA_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)|\
(?# 3:  NUMBER  )(\d+)|\
(?# 4:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 5:  LITERAL )\{(\d+)\}\r\n|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\)))/ni

    TEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n]*))/ni

    RTEXT_REGEXP = /\G(?:\
(?# 1:  LBRA    )(\[)|\
(?# 2:  TEXT    )([^\x00\r\n]*))/ni

    CTEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n\]]*))/ni

    Token = Struct.new(:symbol, :value)

    UNIVERSAL_COMMANDS = [
      "CAPABILITY",
      "NOOP",
      "LOGOUT"
    ]
    NON_AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "AUTHENTICATE",
      "LOGIN"
    ]
    AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "SELECT",
      "CREATE",
      "DELETE",
      "RENAME",
      "SUBSCRIBE",
      "UNSUBSCRIBE",
      "LIST",
      "LSUB",
      "STATUS",
      "APPEND",
      "IDLE"
    ]
    SELECTED_STATE_COMMANDS = AUTHENTICATED_STATE_COMMANDS + [
      "CHECK",
      "CLOSE",
      "EXPUNGE",
      "UID SEARCH",
      "FETCH",
      "UID FETCH",
      "UID STORE"
    ]
    LOGOUT_STATE_COMMANDS = []
    COMMANDS = {
      NON_AUTHENTICATED_STATE => NON_AUTHENTICATED_STATE_COMMANDS,
      AUTHENTICATED_STATE => AUTHENTICATED_STATE_COMMANDS,
      SELECTED_STATE => SELECTED_STATE_COMMANDS,
      LOGOUT_STATE => LOGOUT_STATE_COMMANDS
    }

    def command
      result = NullCommand.new
      token = lookahead
      if token.symbol == T_CRLF || token.symbol == T_EOF
        result = NullCommand.new
      else
        tag = atom
        token = lookahead
        if token.symbol == T_CRLF || token.symbol == T_EOF
          result = MissingCommand.new
        else
          match(T_SPACE)
          name = atom.upcase
          if name == "UID"
            match(T_SPACE)
            name += " " + atom.upcase
          end
          if COMMANDS[@session.state].include?(name)
            result = send(name.tr(" ", "_").downcase)
            result.name = name
            match(T_CRLF)
            match(T_EOF)
          else
            result = UnrecognizedCommand.new
          end
        end
        result.tag = tag
      end
      result.session = @session
      return result
    end

    def capability
      return CapabilityCommand.new
    end

    def noop
      return NoopCommand.new
    end

    def logout
      return LogoutCommand.new
    end

    def authenticate
      match(T_SPACE)
      auth_type = atom.upcase
      case auth_type
      when "CRAM-MD5"
        return AuthenticateCramMD5Command.new
      else
        raise format("unknown auth type: %s", auth_type)
      end
    end

    def login
      match(T_SPACE)
      userid = astring
      match(T_SPACE)
      password = astring
      return LoginCommand.new(userid, password)
    end

    def select
      match(T_SPACE)
      mailbox_name = astring
      return SelectCommand.new(mailbox_name)
    end

    def create
      match(T_SPACE)
      mailbox_name = astring
      return CreateCommand.new(mailbox_name)
    end

    def delete
      match(T_SPACE)
      mailbox_name = mailbox
      return DeleteCommand.new(mailbox_name)
    end

    def rename
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      new_mailbox_name = mailbox
      return RenameCommand.new(mailbox_name, new_mailbox_name)
    end

    def subscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def unsubscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def list
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def lsub
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def list_mailbox
      token = lookahead
      if string_token?(token)
        s = string
        if /\AINBOX\z/ni.match(s)
          return "INBOX"
        else
          return s
        end
      else
        result = ""
        loop do
          token = lookahead
          if list_mailbox_token?(token)
            result.concat(token.value)
            shift_token
          else
            if result.empty?
              parse_error("unexpected token %s", token.symbol)
            else
              if /\AINBOX\z/ni.match(result)
                return "INBOX"
              else
                return result
              end
            end
          end
        end
      end
    end

    LIST_MAILBOX_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS,
      T_STAR,
      T_PERCENT
    ]

    def list_mailbox_token?(token)
      return LIST_MAILBOX_TOKENS.include?(token.symbol)
    end

    def status
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      match(T_LPAR)
      atts = []
      atts.push(status_att)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        atts.push(status_att)
      end
      return StatusCommand.new(mailbox_name, atts)
    end

    def status_att
      att = atom.upcase
      if !/\A(MESSAGES|RECENT|UIDNEXT|UIDVALIDITY|UNSEEN)\z/.match(att)
        parse_error("unknown att `%s'", att)
      end
      return att
    end

    def mailbox
      result = astring
      if /\AINBOX\z/ni.match(result)
        return "INBOX"
      else
        return result
      end
    end

    def append
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
        match(T_SPACE)
        token = lookahead
      else
        flags = []
      end
      if token.symbol == T_QUOTED
        shift_token
        datetime = token.value
        match(T_SPACE)
      else
        datetime = nil
      end
      token = match(T_LITERAL)
      message = token.value
      return AppendCommand.new(mailbox_name, flags, datetime, message)
    end

    def idle
      return IdleCommand.new
    end

    def check
      return NoopCommand.new
    end

    def close
      return CloseCommand.new
    end

    def expunge
      return NoopCommand.new
    end

    def uid_search
      match(T_SPACE)
      token = lookahead
      if token.value == "CHARSET"
        shift_token
        match(T_SPACE)
        charset = astring
        match(T_SPACE)
      else
        charset = "us-ascii"
      end
      return UidSearchCommand.new(search_keys(charset))
    end

    def search_keys(charset)
      result = [search_key(charset)]
      loop do
        token = lookahead
        if token.symbol != T_SPACE
          break
        end
        shift_token
        result.push(search_key(charset))
      end
      return result
    end

    def search_key(charset)
      name = atom
      case name
      when "BODY"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return BodySearchKey.new(s)
      when "HEADER"
        match(T_SPACE)
        header_name = atom.downcase
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return HeaderSearchKey.new(header_name, s)
      when "SEEN"
        return SeenSearchKey.new(@session.mail_store.flags_db)
      when "UNSEEN"
        return UnseenSearchKey.new(@session.mail_store.flags_db)
      else
        return NullSearchKey.new
      end
    end

    def fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return FetchCommand.new(seq_set, atts)
    end

    def uid_fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return UidFetchCommand.new(seq_set, atts)
    end

    def fetch_atts
      token = lookahead
      if token.symbol == T_LPAR
        shift_token
        result = []
        result.push(fetch_att)
        loop do
          token = lookahead
          if token.symbol == T_RPAR
            shift_token
            break
          end
          match(T_SPACE)
          result.push(fetch_att)
        end
        return result
      else
        case token.value
        when "ALL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          return result
        when "FAST"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          return result
        when "FULL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          result.push(BodyFetchAtt.new)
          return result
        else
          return [fetch_att]
        end
      end
    end

    def fetch_att
      token = match(T_ATOM)
      case token.value
      when /\A(?:FLAGS)\z/ni
        return FlagsFetchAtt.new
      when /\A(?:RFC822)\z/ni
        return RFC822FetchAtt.new
      when /\A(?:RFC822\.HEADER)\z/ni
        return RFC822HeaderFetchAtt.new
      when /\A(?:RFC822\.SIZE)\z/ni
        return RFC822SizeFetchAtt.new
      when /\A(?:BODY)?\z/ni
        token = lookahead
        if token.symbol != T_LBRA
          return BodyFetchAtt.new
        end
        return BodySectionFetchAtt.new(section, opt_partial, false)
      when /\A(?:BODY\.PEEK)\z/ni
        return BodySectionFetchAtt.new(section, opt_partial, true)
      when /\A(?:BODYSTRUCTURE)\z/ni
        return BodyStructureFetchAtt.new
      when /\A(?:UID)\z/ni
        return UidFetchAtt.new
      else
        parse_error("unknown attribute `%s'", token.value)
      end
    end

    def section
      match(T_LBRA)
      token = lookahead
      if token.symbol == T_ATOM
        shift_token
        case token.value
        when /\A(?:(?:([0-9.])+\.)?(HEADER|TEXT))\z/ni
          result = Section.new($1, $2.upcase)
        when /\A(?:(?:([0-9.])+\.)?(HEADER\.FIELDS(?:\.NOT)?))\z/ni
          match(T_SPACE)
          result = Section.new($1, $2.upcase, header_list)
        when /\A(?:([0-9.])+\.(MIME))\z/ni
          result = Section.new($1, $2.upcase)
        else
          parse_error("unknown section `%s'", token.value)
        end
      end
      match(T_RBRA)
      return result
    end

    def header_list
      result = []
      match(T_LPAR)
      result.push(astring.upcase)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        result.push(astring.upcase)
      end
      return result
    end

    def opt_partial
      token = lookahead
      if m = /<(\d+)\.(\d+)>/.match(token.value)
        shift_token
        return Partial.new(m[1].to_i, m[2].to_i)
      end
      return nil
    end
    Partial = Struct.new(:offset, :size)

    def uid_store
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      att = store_att_flags
      return UidStoreCommand.new(seq_set, att)
    end

    def store_att_flags
      item = atom
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
      else
        flags = []
        flags.push(flag)
        loop do
          token = lookahead
          if token.symbol != T_SPACE
            break
          end
          shift_token
          flags.push(flag)
        end
      end
      case item
      when /\AFLAGS(\.SILENT)?\z/ni
        return SetFlagsStoreAtt.new(flags, !$1.nil?)
      when /\A\+FLAGS(\.SILENT)?\z/ni
        return AddFlagsStoreAtt.new(flags, !$1.nil?)
      when /\A-FLAGS(\.SILENT)?\z/ni
        return RemoveFlagsStoreAtt.new(flags, !$1.nil?)
      else
        parse_error("unkown data item - `%s'", item)
      end
    end

    FLAG_REGEXP = /\
(?# FLAG        )(\\[^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)/n

    def flag_list
      match(T_LPAR)
      if @str.index(/([^)]*)\)/ni, @pos)
        @pos = $~.end(0)
        return $1.scan(FLAG_REGEXP).collect { |flag, atom|
          atom || flag
        }
      else
        parse_error("invalid flag list")
      end
    end

    EXACT_FLAG_REGEXP = /\A\
(?# FLAG        )\\([^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)\z/n

    def flag
      result = atom
      if !EXACT_FLAG_REGEXP.match(s)
        parse_error("invalid flag")
      end
      return result
    end

    def sequence_set
      s = ""
      loop do
        token = lookahead
        break if !atom_token?(token) && token.symbol != T_STAR
        shift_token
        s.concat(token.value)
      end
      return s.split(/,/n).collect { |i|
        x, y = i.split(/:/n)
        if y.nil?
          parse_seq_number(x)
        else
          parse_seq_number(x) .. parse_seq_number(y)
        end
      }
    end

    def parse_seq_number(s)
      if s == "*"
        return -1
      else
        return s.to_i
      end
    end

    def astring
      token = lookahead
      if string_token?(token)
        return string
      else
        return atom
      end
    end

    def string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value
    end

    STRING_TOKENS = [T_QUOTED, T_LITERAL, T_NIL]

    def string_token?(token)
      return STRING_TOKENS.include?(token.symbol)
    end

    def case_insensitive_string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value.upcase
    end

    def atom
      result = ""
      loop do
        token = lookahead
        if atom_token?(token)
          result.concat(token.value)
          shift_token
        else
          if result.empty?
            parse_error("unexpected token %s", token.symbol)
          else
            return result
          end
        end
      end
    end

    ATOM_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS
    ]

    def atom_token?(token)
      return ATOM_TOKENS.include?(token.symbol)
    end

    def number
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_NUMBER)
      return token.value.to_i
    end

    def nil_atom
      match(T_NIL)
      return nil
    end

    def match(*args)
      token = lookahead
      unless args.include?(token.symbol)
        parse_error('unexpected token %s (expected %s)',
                    token.symbol.id2name,
                    args.collect {|i| i.id2name}.join(" or "))
      end
      shift_token
      return token
    end

    def lookahead
      unless @token
        @token = next_token
      end
      return @token
    end

    def shift_token
      @token = nil
    end

    def next_token
      case @lex_state
      when EXPR_BEG
        if @str.index(BEG_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_ATOM, $+)
          elsif $5
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          elsif $8
            return Token.new(T_BSLASH, $+)
          elsif $9
            return Token.new(T_STAR, $+)
          elsif $10
            return Token.new(T_LBRA, $+)
          elsif $11
            return Token.new(T_RBRA, $+)
          elsif $12
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $13
            return Token.new(T_PLUS, $+)
          elsif $14
            return Token.new(T_PERCENT, $+)
          elsif $15
            return Token.new(T_CRLF, $+)
          elsif $16
            return Token.new(T_EOF, $+)
          else
            parse_error("[Net::IMAP BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_DATA
        if @str.index(DATA_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $5
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          else
            parse_error("[Net::IMAP BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_TEXT
        if @str.index(TEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[Net::IMAP BUG] TEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_RTEXT
        if @str.index(RTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_LBRA, $+)
          elsif $2
            return Token.new(T_TEXT, $+)
          else
            parse_error("[Net::IMAP BUG] RTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_CTEXT
        if @str.index(CTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[Net::IMAP BUG] CTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos) #/
          parse_error("unknown token - %s", $&.dump)
        end
      else
        parse_error("illegal @lex_state - %s", @lex_state.inspect)
      end
    end

    def parse_error(fmt, *args)
      if Ximapd.debug
        $stderr.printf("@str: %s\n", @str.dump)
        $stderr.printf("@pos: %d\n", @pos)
        $stderr.printf("@lex_state: %s\n", @lex_state)
        if @token.symbol
          $stderr.printf("@token.symbol: %s\n", @token.symbol)
          $stderr.printf("@token.value: %s\n", @token.value.inspect)
        end
      end
      raise CommandParseError, format(fmt, *args)
    end
  end

  class CommandParseError < StandardError
  end

  class Command
    attr_reader :session
    attr_accessor :tag, :name

    def initialize
      @session = nil
      @config = nil
      @tag = nil
      @name = nil
    end

    def session=(session)
      @session = session
      @config = session.config
    end

    def send_tagged_ok(code = nil)
      if code.nil?
        @session.send_tagged_ok(@tag, "%s completed", @name)
      else
        @session.send_tagged_ok(@tag, "[%s] %s completed", code, @name)
      end
    end
  end

  class NullCommand < Command
    def exec
      @session.send_bad("Null command")
    end
  end

  class MissingCommand < Command
    def exec
      @session.send_tagged_bad(@tag, "Missing command")
    end
  end

  class UnrecognizedCommand < Command
    def exec
      msg = "Command unrecognized"
      if @session.state == NON_AUTHENTICATED_STATE
        msg.concat("/login please")
      end
      @session.send_tagged_bad(@tag, msg)
    end
  end

  class CapabilityCommand < Command
    def exec
      @session.send_data("CAPABILITY IMAP4REV1 IDLE LOGINDISABLED AUTH=CRAM-MD5")
      send_tagged_ok
    end
  end

  class NoopCommand < Command
    def exec
      @session.sync
      send_tagged_ok
    end
  end

  class LogoutCommand < Command
    def exec
      @session.send_data("BYE IMAP server terminating connection")
      send_tagged_ok
      @session.logout
    end
  end

  class AuthenticateCramMD5Command < Command
    def exec
      challenge = @@challenge_generator.call
      @session.send_continue_req([challenge].pack("m").gsub("\n", ""))
      line = @session.recv_line
      s = line.unpack("m")[0]
      digest = hmac_md5(challenge, @config["password"])
      expected = @config["user"] + " " + digest
      if s == expected
        @session.login
        send_tagged_ok
      else
        sleep(3)
        @session.send_tagged_no(@tag, "AUTHENTICATE failed")
      end
    end

    @@challenge_generator = Proc.new {
      format("<%s.%f@%s>",
             Process.pid, Time.new.to_f,
             TCPSocket.gethostbyname(Socket.gethostname)[0])
    }

    def self.challenge_generator
      return @@challenge_generator
    end

    def self.challenge_generator=(proc)
      @@challenge_generator = proc
    end

    private

    def hmac_md5(text, key)
      if key.length > 64
        key = Digest::MD5.digest(key)
      end

      k_ipad = key + "\0" * (64 - key.length)
      k_opad = key + "\0" * (64 - key.length)
      for i in 0..63
        k_ipad[i] ^= 0x36
        k_opad[i] ^= 0x5c
      end

      digest = Digest::MD5.digest(k_ipad + text)

      return Digest::MD5.hexdigest(k_opad + digest)
    end
  end

  class LoginCommand < Command
    def initialize(userid, password)
      @userid = userid
      @password = password
    end

    def exec
      @session.send_tagged_no(@tag, "LOGIN failed")
    end
  end

  class SelectCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      begin
        status = @session.mail_store.get_mailbox_status(@mailbox_name)
        @session.send_data("%d EXISTS", status.messages)
        @session.send_data("%d RECENT", status.recent)
        @session.send_ok("[UIDVALIDITY %d] UIDs valid", status.uidvalidity)
        @session.send_ok("[UIDNEXT %d] Predicted next UID", status.uidnext)
        @session.send_data("FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
        @session.send_ok("[PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited")
        @session.select(@mailbox_name)
        send_tagged_ok("READ-WRITE")
      rescue MailboxError
        @session.send_tagged_no(@tag, "%s", $!)
      end
    end
  end

  class CreateCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      @session.mail_store.create_mailbox(@mailbox_name)
      send_tagged_ok
    end
  end

  class DeleteCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      if /\A(INBOX|ml|history|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't delete %s", @mailbox_name)
        return
      end
      @session.mail_store.delete_mailbox(@mailbox_name)
      send_tagged_ok
    end
  end

  class RenameCommand < Command
    def initialize(mailbox_name, new_mailbox_name)
      @mailbox_name = mailbox_name
      @new_mailbox_name = new_mailbox_name
    end

    def exec
      if /\A(INBOX|ml|history|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't rename %s", @mailbox_name)
        return
      end
      @session.mail_store.rename_mailbox(@mailbox_name, @new_mailbox_name)
      send_tagged_ok
    end
  end

  class ListCommand < Command
    include DataFormat

    def initialize(reference_name, mailbox_name)
      @reference_name = reference_name
      @mailbox_name = mailbox_name
    end

    def exec
      if !@reference_name.empty?
        @session.send_tagged_no(@tag, "%s failed", @name)
        return
      end
      if @mailbox_name.empty?
        @session.send_data("%s (\\Noselect) \"/\" \"\"", @name)
        send_tagged_ok
        return
      end
      pat = @mailbox_name.gsub(/\*|%|[^*%]+/n) { |s|
        case s
        when "*"
          ".*"
        when "%"
          "[^/]*"
        else
          Regexp.quote(s)
        end
      }
      re = Regexp.new("\\A" + pat + "\\z", nil, "n")
      mailboxes = @session.mail_store.mailboxes.to_a.select { |mbox_name,|
        re.match(mbox_name)
      }
      mailboxes.sort_by { |i| i[0] }.each do |mbox_name, mbox|
        @session.send_data("%s (%s) \"/\" %s",
                           @name, mbox["flags"], quoted(mbox_name))
      end
      send_tagged_ok
    end
  end

  class StatusCommand < Command
    include DataFormat

    def initialize(mailbox_name, atts)
      @mailbox_name = mailbox_name
      @atts = atts
    end

    def exec
      status = @session.mail_store.get_mailbox_status(@mailbox_name)
      s = @atts.collect { |att|
        format("%s %d", att, status.send(att.downcase))
      }.join(" ")
      @session.send_data("STATUS %s (%s)", quoted(@mailbox_name), s)
      send_tagged_ok
    end
  end

  class AppendCommand < Command
    def initialize(mailbox_name, flags, datetime, message)
      @mailbox_name = mailbox_name
      @flags = flags
      @datetime = datetime
      @message = message
    end

    def exec
      @session.mail_store.import_mail(@message, @mailbox_name, @flags.join(" "))
      send_tagged_ok
    end
  end

  class IdleCommand < Command
    def exec
      @session.sync
      @session.send_continue_req("Waiting for DONE")
      line = @session.recv_line
      send_tagged_ok
    end
  end

  class CloseCommand < Command
    def exec
      status = @session.close_mailbox
      send_tagged_ok
    end
  end

  class UidSearchCommand < Command
    def initialize(keys)
      @keys = keys
    end

    def exec
      query = @keys.collect { |key| key.to_query }.reject { |q|
        q.empty?
      }.join(" ")
      uids = @session.mail_store.uid_search(@session.current_mailbox, query)
      for key in @keys
        uids = key.select(uids)
      end
      @session.send_data("SEARCH %s", uids.join(" "))
      send_tagged_ok
    end
  end

  class NullSearchKey
    def to_query
      return ""
    end

    def select(uids)
      return uids
    end
  end

  class BodySearchKey < NullSearchKey
    def initialize(value)
      @value = value
    end

    def to_query
      return @value
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
      when "subject", "from", "to", "cc"
        return format("%s : %s", @name, quote_query(@value))
      when "x-ml-name", "x-mail-count"
        return format("%s = %s", @name, quote_query(@value))
      else
        return ""
      end
    end
  end

  class SeenSearchKey < NullSearchKey
    def initialize(flags_db)
      @flags_db = flags_db
    end

    def select(uids)
      return uids.select { |uid|
        /\\Seen\b/ni.match(@flags_db[uid])
      }
    end
  end

  class UnseenSearchKey < SeenSearchKey
    def select(uids)
      return uids.select { |uid|
        !/\\Seen\b/ni.match(@flags_db[uid])
      }
    end
  end

  class FetchCommand < Command
    def initialize(sequence_set, atts)
      @sequence_set = sequence_set
      @atts = atts
    end

    def exec
      mails = @session.mail_store.fetch(@session.current_mailbox,
                                        @sequence_set)
      for mail in mails
        data = @atts.collect { |att|
          att.fetch(mail)
        }.join(" ")
        @session.send_data("%d FETCH (%s)", mail.seqno, data)
      end
      send_tagged_ok
    end
  end

  class UidFetchCommand < FetchCommand
    def initialize(sequence_set, atts)
      super(sequence_set, atts)
      if !@atts[0].kind_of?(UidFetchAtt)
        @atts.unshift(UidFetchAtt.new)
      end
    end

    def exec
      mails = @session.mail_store.uid_fetch(@session.current_mailbox,
                                            @sequence_set)
      for mail in mails
        data = @atts.collect { |att|
          att.fetch(mail)
        }.join(" ")
        @session.send_data("%d FETCH (%s)", mail.uid, data)
      end
      send_tagged_ok
    end
  end

  class EnvelopeFetchAtt
    def fetch(mail)
    end
  end

  class FlagsFetchAtt
    def fetch(mail)
      return format("FLAGS (%s)", mail.flags)
    end
  end

  class InternalDateFetchAtt
    def fetch(mail)
    end
  end

  class RFC822FetchAtt
    include DataFormat

    def fetch(mail)
      return format("RFC822 %s", literal(mail.to_s))
    end
  end

  class RFC822HeaderFetchAtt
    include DataFormat

    def fetch(mail)
      return format("RFC822.HEADER %s", literal(mail.header))
    end
  end

  class RFC822SizeFetchAtt
    def fetch(mail)
      return format("RFC822.SIZE %s", mail.size)
    end
  end

  class RFC822TextFetchAtt
    def fetch(mail)
    end
  end

  class BodyFetchAtt
    def fetch(mail)
      return format("BODY %s", mail.body)
    end
  end

  class BodyStructureFetchAtt
    def fetch(mail)
      return format("BODYSTRUCTURE %s", mail.body)
    end
  end

  class UidFetchAtt
    def fetch(mail)
      return format("UID %s", mail.uid)
    end
  end

  class BodySectionFetchAtt
    include DataFormat

    def initialize(section, partial, peek)
      @section = section
      @partial = partial
      @peek = peek
    end

    def fetch(mail)
      if @section.nil?
        if @partial.nil?
          return format("BODY[] %s", literal(mail.to_s))
        else
          s = mail.to_s[@partial.offset, @partial.size] 
          return format("BODY[]<%d> %s", @partial.offset, literal(s))
        end
      end
      case @section.text
      when "HEADER.FIELDS"
        s = mail.header_fields(@section.header_list)
        fields = @section.header_list.collect { |i|
          quoted(i)
        }.join(" ")
        return format("BODY[HEADER.FIELDS (%s)] %s",
                      fields, literal(s))
      end
    end
  end

  Section = Struct.new(:part, :text, :header_list)

  class UidStoreCommand < Command
    def initialize(sequence_set, att)
      @sequence_set = sequence_set
      @att = att
    end

    def exec
      mails = @session.mail_store.uid_fetch(@session.current_mailbox,
                                            @sequence_set)
      for mail in mails
        @att.store(mail)
        if !@att.silent?
          @session.send_data("%d FETCH (FLAGS (%s))", mail.uid, mail.flags)
        end
      end
      send_tagged_ok
    end
  end

  class FlagsStoreAtt
    def initialize(flags, silent = false)
      @flags = flags
      @silent = silent
    end

    def silent?
      return @silent
    end
  end

  class SetFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      mail.flags = @flags.join(" ")
    end
  end

  class AddFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      flags = mail.flags(false).split(/ /)
      flags |= @flags
      mail.flags = flags.join(" ")
    end
  end

  class RemoveFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      flags = mail.flags(false).split(/ /)
      flags -= @flags
      mail.flags = flags.join(" ")
    end
  end

  class MailboxError < StandardError; end
  class MailboxExistError < MailboxError; end
  class NoMailboxError < MailboxError; end
  class MailboxAccessError < MailboxError; end
end

if $0 == __FILE__
  require "optparse"

  config_file = File.expand_path("~/.ximapd")
  action = "start"
  opts = OptionParser.new { |opts|
    opts.banner = "usage: #{File.basename($0)} [options]"

    opts.separator("")
    opts.separator("options:")

    opts.on("-f", "--config-file=PATH", "path to .ximapd") do |arg|
      config_file = File.expand_path(arg)
    end

    opts.on("-i", "--import", "import mail") do
      action = "import"
    end

    opts.on("--import-mbox", "import mbox") do
      action = "import_mbox"
    end

    opts.on("-s", "--stop", "stop ximapd") do
      action = "stop"
    end

    opts.on("-d", "--debug", "turn on debug mode") do
      Ximapd.debug = true
    end

    opts.on("-v", "--verbose", "turn on verbose mode") do
      Ximapd.verbose = true
    end

    opts.on("-V", "--version", "print version") do
      action = "version"
    end
  }
  begin
    opts.parse!(ARGV)
    config = File.open(config_file) { |f|
      if f.stat.mode & 0004 != 0
        raise format("%s is world readable", config_file)
      end
      YAML.load(f)
    }
    imapd = Ximapd.new(config)
    case action
    when "import"
      mail_store = Ximapd::MailStore.new(config)
      begin
        if ARGV.empty?
          mail_store.import_file(STDIN)
        else
          mail_store.import(ARGV)
        end
      ensure
        mail_store.close
      end
    when "import_mbox"
      mail_store = Ximapd::MailStore.new(config)
      begin
        if ARGV.empty?
          mail_store.import_mbox_file(STDIN)
        else
          mail_store.import_mbox(ARGV)
        end
      ensure
        mail_store.close
      end
    when "stop"
      imapd.stop
    when "version"
      imapd.print_version
    else
      imapd.start
    end
  rescue
    raise if Ximapd.debug
    STDERR.printf("%s: %s\n", $0, $!)
    exit(1)
  end
end
