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

class Ximapd
  DEFAULT_CHARSET = "iso-2022-jp"
  DEFAULT_ML_HEADER_FIELDS = [
    "x-ml-name",
    "list-id",
    "mailing-list"
  ]
  DEFAULT_MAILBOXES = {
    "ml" => {
      "flags" => "\\Noselect"
    },
    "queries" => {
      "flags" => "\\Noselect"
    },
    "static" => {
      "flags" => "\\Noselect"
    }
  }

  module DataFormat
    module_function

    def quoted(s)
      if s.nil?
        return "NIL"
      else
        return format('"%s"', s.to_s.gsub(/[\r\n]/, "").gsub(/[\\"]/n, "\\\\\\&"))
      end
    end

    def literal(s)
      return format("{%d}\r\n%s", s.length, s)
    end
  end

  class MailData
    attr_reader :raw_data, :uid, :flags, :internal_date, :text, :properties
    attr_reader :parsed_mail

    def initialize(raw_data, uid, flags, internal_date, text, properties,
                   parsed_mail)
      @raw_data = raw_data
      @uid = uid
      @flags = flags
      @internal_date = internal_date
      @text = text
      @properties = properties
      @parsed_mail = parsed_mail
    end

    def to_s
      return @raw_data
    end

    def header
      return @parsed_mail.header
    end

    def multipart?
      return @parsed_mail.multipart?
    end

    def body
      return @parsed_mail.body
    end
  end

  class NullMessage
    attr_reader :header, :body

    def initialize
      @header = {}
      @body = ""
    end

    def multipart?
      return false
    end
  end

  MailboxStatus = Struct.new(:messages, :recent, :uidnext, :uidvalidity,
                             :unseen)

  class MailStore
    include MonitorMixin

    attr_reader :config, :path, :mailbox_db, :mailbox_db_path
    attr_reader :plugins
    attr_reader :uid_seq, :uidvalidity_seq, :mailbox_id_seq
    attr_reader :backend_class

    def initialize(config)
      super()
      @config = config
      @logger = @config["logger"]
      @path = File.expand_path(@config["data_dir"])
      FileUtils.mkdir_p(@path)
      FileUtils.mkdir_p(File.expand_path("mails", @path))
      uid_seq_path = File.expand_path("uid.seq", @path)
      @uid_seq = Sequence.new(uid_seq_path)
      uidvalidity_seq_path = File.expand_path("uidvalidity.seq", @path)
      @uidvalidity_seq = Sequence.new(uidvalidity_seq_path)
      mailbox_id_seq_path = File.expand_path("mailbox_id.seq", @path)
      @mailbox_id_seq = Sequence.new(mailbox_id_seq_path, 0)
      @mailbox_db_path = File.expand_path("mailbox.db", @path)
      case @config["db_type"].to_s.downcase
      when "pstore"
        @mailbox_db = PStore.new(@mailbox_db_path)
      else
        @mailbox_db = YAML::Store.new(@mailbox_db_path)
      end
      override_commit_new(@mailbox_db)
      @mail_parser = RMail::Parser.new
      @default_charset = @config["default_charset"] || DEFAULT_CHARSET
      @ml_header_fields =
        @config["ml_header_fields"] || DEFAULT_ML_HEADER_FIELDS
      @last_peeked_uids = {}
      @backend_ref_count = 0
      lock_path = File.expand_path("lock", @path)
      @lock = File.open(lock_path, "w+")
      @lock_count = 0
      backend_name = @config["backend"] || "Rast"
      lib = File.expand_path(backend_name.downcase, Backend.directory)
      require lib
      @backend_class = Ximapd.const_get(backend_name + "Backend")
      @backend = @backend_class.new(self)
      synchronize do
        if @uidvalidity_seq.current.nil?
          @uidvalidity_seq.current = 1
        end
        if @mailbox_id_seq.current.nil?
          @mailbox_id_seq.current = 0
        end
        @mailbox_db.transaction do
          @mailbox_db["mailboxes"] ||= DEFAULT_MAILBOXES.dup
          @mailbox_db["mailing_lists"] ||= {}
          convert_old_mailbox_db
          @plugins = Plugin.create_plugins(@config, self)
        end
        @backend.setup
        begin
          create_mailbox("INBOX")
        rescue
          # OK
        end
      end
    end

    def close
      @lock.close
    end

    def lock
      mon_enter
      if @lock_count == 0
        @lock.flock(File::LOCK_EX)
        @backend.standby
      end
      @lock_count += 1
    end

    def unlock
      @lock_count -= 1
      if @lock_count == 0 && !@lock.closed?
        @backend.relax
        @lock.flock(File::LOCK_UN)
      end
      mon_exit
    end

    def synchronize
      lock
      begin
        yield
      ensure
        unlock
      end
    end

    def write_last_peeked_uids
      return if @last_peeked_uids.empty?
      @mailbox_db.transaction do
        @last_peeked_uids.each do |name, uid|
          mailbox = @mailbox_db["mailboxes"][name]
          if mailbox && mailbox["last_peeked_uid"] < uid
            mailbox["last_peeked_uid"] = uid
          end
        end
        @last_peeked_uids.clear
      end
    end

    def mailboxes
      @mailbox_db.transaction(true) do
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
        delete_mailbox_internal(name)
      end
    end

    def rename_mailbox(name, new_name)
      @mailbox_db.transaction do
        if @mailbox_db["mailboxes"].include?(new_name)
          raise MailboxExistError, format("%s already exists", new_name)
        end
        mkdir_p(File.dirname(new_name))
        pat = "\\A" + Regexp.quote(name) + "(/.*)?\\z"
        re = Regexp.new(pat, nil, "n")
        mailboxes = @mailbox_db["mailboxes"].select { |k, v|
          re.match(k)
        }
        if mailboxes.empty?
          raise NoMailboxError, format("%s does not exist", name)
        end
        for k, v in mailboxes
          new_key = k.sub(re) { $1 ? new_name + $1 : new_name }
          @mailbox_db["mailboxes"].delete(k)
          @mailbox_db["mailboxes"][new_key] = v
          list_id = v["list_id"]
          if list_id
            @mailbox_db["mailing_lists"][list_id]["mailbox"] = new_key
          end
        end
        query = extract_query(new_name)
        if query
          @mailbox_db["mailboxes"][new_name]["query"] = query
        end
      end
    end

    def get_mailbox_status(mailbox_name, read_only)
      @mailbox_db.transaction(true) do
        mailbox = get_mailbox(mailbox_name)
        if /\\Noselect/ni.match(mailbox["flags"])
          raise NotSelectableMailboxError.new("can't open #{mailbox_name}: not a selectable mailbox")
        end
        mailbox_status = mailbox.status
        mailbox_status.uidnext = @uid_seq.peek_next
        mailbox_status.uidvalidity = @uidvalidity_seq.current
        unless read_only
          @last_peeked_uids[mailbox_name] = @uid_seq.current.to_i
        end
        return mailbox_status
      end
    end

    def import(args, mailbox_name = nil)
      open_backend do |backend|
        for arg in args
          filenames = []
          Find.find(arg) do |filename|
            if File.file?(filename)
              filenames.push(filename)
            end
          end
          if @config.key?("exclude")
            pat = Regexp.new(@config["exclude"], nil, "n")
            filenames = filenames.reject { |filename|
              pat.match(filename)
            }
          end
          if @config["progress"]
            progress_bar = ProgressBar.new(arg.slice(/.{1,13}\z/n),
                                           filenames.length)
          else
            progress_bar = NullObject.new
          end
          for filename in filenames
            File.open(filename) do |f|
              import_mail_internal(f.read, mailbox_name, "", f.mtime)
            end
            progress_bar.inc
          end
          progress_bar.finish
        end
      end
    end

    def import_file(f, mailbox_name = nil)
      open_backend do |backend|
        return import_mail_internal(f.read, mailbox_name)
      end
    end

    def import_mbox(args, mailbox_name = nil)
      open_backend do |backend|
        for arg in args
          Find.find(arg) do |filename|
            if File.file?(filename)
              File.open(filename) do |f|
                import_mbox_internal(backend, f, mailbox_name)
              end
            end
          end
        end
      end
    end

    def import_mbox_file(f, mailbox_name = nil)
      open_backend do |backend|
        import_mbox_internal(backend, f, mailbox_name)
      end
    end

    def import_imap(folders, mailbox_name = nil)
      host = @config["remote_host"]
      port = @config["remote_port"]
      ssl = @config["remote_ssl"]
      if port.nil?
        if ssl
          port = 993
        else
          port = 143
        end
      end
      auth = @config["remote_auth"]
      if auth.nil?
        auth = "CRAM-MD5"
      end
      user = @config["remote_user"]
      pass = @config["remote_password"]

      @logger.info("importing from #{host} via IMAP...")
      imap = Net::IMAP.new(host, port, ssl)
      imap.authenticate(auth, user, pass)

      visited_folders = Set.new
      open_backend do |backend|
        folders.each do |f|
          folders = imap.list('', f)
          if folders.nil?
            @logger.warn("no folder matches: #{f}")
            next
          end
          folders.each do |folder|
            next if visited_folders.include?(folder.name)
            begin
              imap.select(folder.name)
              mail_count = imap.responses["EXISTS"][-1]
              if mail_count == 0
                @logger.info("0 messages in #{folder.name}")
                next
              end
              imported_uids = Set.new
              progress_bar = NullObject.new
              handler = Proc.new { |resp|
                if resp.kind_of?(Net::IMAP::UntaggedResponse) &&
                  resp.name == "FETCH"
                  mail = resp.data
                  # IMAP server may return only FLAGS if \Seen is set.
                  if !imported_uids.include?(mail.attr["UID"]) &&
                    mail.attr["BODY[]"]
                    indate = DateTime.strptime(mail.attr["INTERNALDATE"], 
                                               "%d-%b-%Y %H:%M:%S %z")
                    if @config["import_imap_flags"]
                      flags = mail.attr["FLAGS"].collect { |flag|
                        if flag.kind_of?(Symbol)
                          '\\' + flag.to_s
                        else
                          flag.to_s
                        end
                      }.join(" ")
                    else
                      flags = ""
                    end
                    import_mail_internal(mail.attr["BODY[]"], mailbox_name,
                                         flags, indate)
                    imported_uids.add(mail.attr["UID"])
                    progress_bar.inc
                    imap.responses["FETCH"].clear
                  end
                end
              }
              imap.add_response_handler(handler)
              begin
                fetch_attrs = ["UID", "BODY[]", "INTERNALDATE"]
                if @config["import_imap_flags"]
                  fetch_attrs.push("FLAGS")
                end
                if @config["import_all"]
                  @logger.info("#{mail_count} messages in #{folder.name}")
                  if @config["progress"]
                    progress_bar = ProgressBar.new(folder.name, mail_count)
                  end
                  imap.fetch(1 .. -1, fetch_attrs)
                else
                  uids = imap.uid_search("NOT KEYWORD XimapdImported")
                  @logger.info("#{uids.length} unseen messages " + 
                               "in #{folder.name}")
                  if @config["progress"]
                    progress_bar = ProgressBar.new(folder.name, uids.length)
                  end
                  while uids.length > 0
                    imap.uid_fetch(uids.slice!(0, 100), fetch_attrs)
                  end
                end
                progress_bar.finish
              ensure
                imap.remove_response_handler(handler)
              end
              flags = ["XimapdImported"]
              unless @config["keep"]
                flags.push(:Deleted)
              end
              uids = imported_uids.to_a.sort
              while uids.length > 0
                imap.uid_store(uids.slice!(0, 100), "+FLAGS.SILENT", flags)
              end
            rescue StandardError => e
              @logger.log_exception(e, folder.name)
            ensure
              visited_folders.add(folder.name)
              imap.close
            end
          end
        end
      end
      @logger.info("imported from #{host}")
    end

    def import_mail(str, mailbox_name = nil, flags = "", indate = nil, override = {})
      open_backend do
        import_mail_internal(str, mailbox_name, flags, indate, override)
      end
    end

    def index_mail(mail, filename)
      begin
        @backend.register(mail, filename)
        s = mail.properties["x-ml-name"]
        if !s.empty? && mail.properties["mailbox-id"] == 0 &&
          !@mailbox_db["mailing_lists"].key?(s)
          mbox_name = get_mailbox_name_from_x_ml_name(s)
          mailbox_name = format("ml/%s", Net::IMAP.encode_utf7(mbox_name))
          query = @backend.class.make_list_query(mail.properties["x-ml-name"])
          begin
            create_mailbox_internal(mailbox_name, query)
            mailbox = get_mailbox(mailbox_name)
            mailbox["list_id"] = s
            @mailbox_db["mailing_lists"][s] = {
              "creator_uid" => mail.uid,
              "mailbox" => mailbox_name
            }
          rescue MailboxExistError
          end
        end
      rescue Exception => e
        @logger.log_exception(e, "backend_mail")
      end
    end

    def get_mailbox(name)
      if name == "DEFAULT"
        return DefaultMailbox.new(self)
      end
      data = @mailbox_db["mailboxes"][name]
      unless data
        raise NoMailboxError.new("no such mailbox")
      end
      class_name = data["class"]
      if class_name
        return Ximapd.const_get(class_name).new(self, name,
                                                @mailbox_db["mailboxes"][name])
      else
        return SearchBasedMailbox.new(self, name,
                                      @mailbox_db["mailboxes"][name])
      end
    end

    def delete_mails(mails)
      open_backend do |backend|
        for mail in mails
          for plugin in @plugins
            plugin.on_delete_mail(mail)
          end
          mail.delete
        end
      end
    end

    def open_backend(*args)
      synchronize do
        if @backend_ref_count == 0
          @backend.open(*args)
        end
        @backend_ref_count += 1
        begin
          yield(@backend)
        ensure
          @backend_ref_count -= 1
          if @backend_ref_count == 0
            @backend.close
          end
        end
      end
    end

    def rebuild_index
      @logger.info("rebuilding index...")
      if @config["delete_ml_mailboxes"]
        @mailbox_db.transaction do
          for k, v in @mailbox_db["mailing_lists"]
            delete_mailbox_internal(v["mailbox"]) if v.key?("mailbox")
          end
          @mailbox_db["mailing_lists"].clear
          delete_mailbox_internal("ml")
          @mailbox_db["mailboxes"]["ml"] = DEFAULT_MAILBOXES["ml"]
        end
      end
      @backend.rebuild_index do
        mailbox_names = {}
        @mailbox_db.transaction do
          for mailbox_name, mailbox_data in @mailbox_db["mailboxes"]
            id = mailbox_data["id"]
            if id
              mailbox_names[id] = mailbox_name
            end
          end
        end
        open_backend do
          mail_dir = File.expand_path("mails", @path)
          Dir.glob(mail_dir + "/*/*").sort.each do |dir|
            reindex_month(dir)
          end
        end
      end
      @uidvalidity_seq.next
      @logger.info("rebuilt index")
    end

    def get_next_mailbox_id
      return @mailbox_id_seq.next
    end

    private

    def override_commit_new(db)
      def db.commit_new(f)
        f.truncate(0)
        f.rewind
        new_file = @filename + ".new"
        File.open(new_file) do |nf|
          nf.binmode
          FileUtils.copy_stream(nf, f)
        end
        f.fsync
        File.unlink(new_file)
      end
    end

    def convert_old_mailbox_db
      if @mailbox_db.root?("status")
        @uid_seq.current = @mailbox_db["status"]["last_uid"]
        @uidvalidity_seq.current = @mailbox_db["status"]["uidvalidity"]
        @mailbox_id_seq.current = @mailbox_db["status"]["last_mailbox_id"]
        @mailbox_db.delete("status")
      end
      if @mailbox_db.root?("mailing-lists")
        for key, val in @mailbox_db["mailing-lists"]
          @mailbox_db["mailing_lists"][key] = {
            "creator_uid" => val
          }
        end
        @mailbox_db.delete("mailing-lists")
      end
      @mailbox_db["mailboxes"]["static"] ||= {
        "flags" => "\\Noselect"
      }
    end

    def strip_unix_from(str, indate)
      str.sub!(/\AFrom\s+\S+\s+(.*)\r\n/) do
        if indate.nil?
          begin
            indate = DateTime.strptime($1 + " " + TIMEZONE,
                                       "%a %b %d %H:%M:%S %Y %z")
          rescue
          end
        end
        ""
      end
      return indate
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

    def import_mail_internal(str, mailbox_name = nil, flags = "", indate = nil, override = {})
      uid = get_next_uid
      mail = parse_mail(str, uid, flags, indate, override)
      @mailbox_db.transaction do
        if mailbox_name
          mailbox = get_mailbox(mailbox_name)
        else
          mailbox = nil
          for plugin in @plugins
            begin
              mbox_name = plugin.filter(mail)
              if mbox_name == "REJECT"
                @logger.add(Logger::INFO, "rejected: from=<#{mail.properties['from']}> subject=<#{mail.properties['subject'].gsub(/[ \t]*\n[ \t]+/, ' ')}> date=<#{mail.properties['date']}>")
                return 0
              end
              if mbox_name
                mailbox = get_mailbox(mbox_name)
                break
              end
            rescue Exception => e
              @logger.log_exception(e)
            end
          end
          mailbox ||= DefaultMailbox.new(self)
        end
        mailbox.import(mail)
        @logger.add(Logger::INFO, "imported: uid=#{mail.uid} from=<#{mail.properties['from']}> subject=<#{mail.properties['subject'].gsub(/[ \t]*\n[ \t]+/, ' ')}> date=<#{mail.properties['date']}> mailbox=<#{mailbox.name}>")
      end
      return mail.uid
    end

    def get_mailbox_name_from_x_ml_name(s)
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
      return mbox
    end

    def create_mailbox_internal(name, query = nil)
      if @mailbox_db["mailboxes"].key?(name)
        raise MailboxExistError, format("mailbox already exist - %s", name)
      end
      if /\Astatic\//u.match(name)
        mailbox = StaticMailbox.new(self, name, "flags" => "")
        mailbox.save
        return
      end
      mailbox = {
        "flags" => "",
        "last_peeked_uid" => 0
      }
      if query.nil?
        query = extract_query(name)
        if query.nil?
          mailbox_id = get_next_mailbox_id
          query = @backend.class.make_default_query(mailbox_id)
          mailbox["id"] = mailbox_id
        end
      end
      mailbox["query"] = query
      @mailbox_db["mailboxes"][name] = mailbox
    end

    def extract_query(mailbox_name)
      s = mailbox_name.slice(/\Aqueries\/(.*)/u, 1)
      return nil if s.nil?
      query = @backend.class.make_query(Net::IMAP.decode_utf7(s))
      begin
        open_backend do |backend|
          result = backend.try_query(query)
        end
        return query
      rescue
        raise InvalidQueryError.new("invalid query")
      end
    end

    def import_mbox_internal(backend, f, mailbox_name = nil)
      s = nil
      f.each_line do |line|
        if /\AFrom\s+\S+\s+[A-Z][a-z]{2} [A-Z][a-z]{2}\s+\d+ \d\d:\d\d:\d\d \d+/.match(line)
          if s
            uid = import_mail_internal(s, mailbox_name)
          end
          s = line
        else
          s.concat(line) if s
        end
      end
      if s
        uid = import_mail_internal(s, mailbox_name)
      end
    end

    def delete_mailbox_internal(name)
      pat = "\\A" + Regexp.quote(name) + "(/.*)?\\z"
      re = Regexp.new(pat, nil, "n")
      deleted_mailboxes = []
      @mailbox_db["mailboxes"].delete_if { |k, v|
        if re.match(k)
          deleted_mailboxes.push(v)
          true
        else
          false
        end
      }
      for mbox in deleted_mailboxes
        list_id = mbox["list_id"]
        if list_id
          @mailbox_db["mailing_lists"].delete(list_id)
        end
      end
    end

    def reindex_month(dir)
      filenames = []
      Find.find(dir) do |filename|
        if File.file?(filename) && /\/\d+\z/.match(filename)
          filenames.push(filename)
        end
      end
      if @config["progress"]
        month = dir.slice(/\d+\/\d+\z/)
        progress_bar = ProgressBar.new(month, filenames.length)
      else
        progress_bar = NullObject.new
      end
      for filename in filenames
        reindex_mail(filename)
        progress_bar.inc
      end
      progress_bar.finish
    end

    def reindex_mail(filename)
      begin
        str = File.read(filename)
        uid = filename.slice(/\/(\d+)\z/, 1).to_i
        flags = @backend.get_old_flags(uid) || "\\Seen"
        indate = File.mtime(filename)
        mail = parse_mail(str, uid, flags, indate)
        begin
          mail.properties["mailbox-id"] =
            File.read(filename + ".mailbox-id").to_i
        rescue Errno::ENOENT
        end
        @mailbox_db.transaction do
          index_mail(mail, filename)
        end
      rescue StandardError => e
        @logger.log_exception(e)
      end
    end

    def parse_mail(mail, uid, flags, indate, override = {})
      mail.gsub!(/\r?\n/, "\r\n")
      indate = strip_unix_from(mail, indate)
      if indate
        indate = indate.to_time.getlocal.to_datetime
      else
        indate = DateTime.now
      end
      properties = Hash.new("")
      properties["uid"] = uid
      properties["size"] = mail.size
      properties["flags"] = ""
      properties["internal-date"] = indate.to_time.getlocal.strftime("%Y-%m-%dT%H:%M:%S")
      properties["date"] = properties["internal-date"]
      properties["x-mail-count"] = 0
      properties["mailbox-id"] = 0
      begin
        m = @mail_parser.parse(mail.gsub(/\r\n/, "\n"))
        properties = extract_properties(m, properties, override)
        body = extract_body(m)
      rescue Exception => e
        @logger.log_exception(e, "failed to parse mail uid=#{uid}",
                              Logger::WARN)
        header, body = *mail.split(/^\r\n/)
        body = to_utf8(body, @default_charset)
      end
      return MailData.new(mail, uid, flags, indate, body, properties,
                          m || NullMessage.new)
    end

    def get_mailbox_id(mailbox_name)
      if mailbox_name.nil?
        mailbox_id = 0
      else
        mailbox = @mailbox_db["mailboxes"][mailbox_name]
        if mailbox.nil?
          raise NoMailboxError.new("no such mailbox")
        end
        mailbox_id = mailbox["id"]
        if mailbox_id.nil?
          raise MailboxAccessError.new("can't import to mailbox without id")
        end
      end
      return mailbox_id
    end

    def get_next_uid
      return @uid_seq.next
    end

    def extract_body(mail)
      if mail.multipart?
        return mail.body.collect { |part|
          extract_body(part)
        }.join("\n")
      else
        case mail.header.content_type("text/plain")
        when "text/plain"
          return decode_body(mail)
        when "text/html", "text/xml"
          return decode_body(mail).gsub(/<.*?>/um, "")
        else
          return ""
        end
      end
    end

    def decode_body(mail)
      charset = mail.header.params("content-type", {})["charset"] ||
        @default_charset
      return to_utf8(mail.decode, charset)
    end

    def to_utf8(src, charset)
      begin
        return Iconv.conv("utf-8", charset, src)
      rescue
        return NKF.nkf("-m0 -w", src)
      end
    end

    def guess_list_name(fname, mail)
      ret = nil

      if mail.header.include?(fname)
        value = mail.header[fname]
        ret = value
        case fname
        when 'list-id'
          ret = $1 if /<([^<>]+)>/ =~ value
        when 'x-ml-address'
          ret = $& if /\b[^<>@\s]+@[^<>@\s]+\b/ =~ value
        when 'x-mailing-list', 'mailing-list'
          ret = $1 if /<([^<>@]+@[^<>@]+)>/ =~ value
        when 'x-ml-name'
          # noop
        when 'sender'
          if /\bowner-([^<>@\s]+@[^<>@\s]+)\b/ =~ value
            ret = $1
          else
            ret = nil
          end
        when 'x-loop'
          ret = $& if /\b[^<>@\s]+@[^<>@\s]+\b/ =~ value
        end
      end

      ret
    end

    def extract_properties(mail, properties, override)
      for field in ["subject", "from", "to", "cc", "bcc"]
        properties[field] = get_header_field(mail, field)
      end
      begin
        properties["date"] = DateTime.parse(mail.header["date"].to_s).to_time.getlocal.strftime("%Y-%m-%dT%H:%M:%S")
      rescue Exception => e
        @logger.log_exception(e, "failed to parse Date", Logger::WARN)
      end
      s = nil
      @ml_header_fields.each do |field_name|
        s = guess_list_name(field_name, mail)
        break if s
      end
      properties["x-ml-name"] = decode_encoded_word(s.to_s)
      properties["x-mail-count"] = mail.header["x-mail-count"].to_s.to_i
      return properties.merge(override)
    end

    def get_header_field(mail, field)
      return decode_encoded_word(mail.header[field].to_s)
    end

    def decode_encoded_word(s)
      return NKF.nkf("-w", s)
    end
  end
end
