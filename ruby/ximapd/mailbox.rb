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
  class Mailbox
    attr_reader :mail_store, :name

    def initialize(mail_store, name, data)
      @mail_store = mail_store
      @name = name
      @data = data
      @config = mail_store.config
    end

    def [](key)
      return @data[key]
    end

    def []=(key, val)
      @data[key] = val
    end

    def save
      @data["class"] = self.class.name.slice(/\AXimapd::(.*)\z/, 1)
      @mail_store.mailbox_db["mailboxes"][@name] = @data
    end

    def import(mail_data)
      raise SubclassResponsibilityError.new
    end

    def get_mail_path(mail)
      raise SubclassResponsibilityError.new
    end

    def status
      raise SubclassResponsibilityError.new
    end

    def uid_search(query)
      raise SubclassResponsibilityError.new
    end

    def uid_search_by_keys(keys)
      raise SubclassResponsibilityError.new
    end

    def fetch(sequence_set)
      raise SubclassResponsibilityError.new
    end

    def uid_fetch(sequence_set)
      raise SubclassResponsibilityError.new
    end

    def get_mail(uid)
      raise SubclassResponsibilityError.new
    end
  end

  class SearchBasedMailbox < Mailbox
    def import(mail_data)
      if @data.key?("id")
        mail_data.properties["mailbox-id"] = @data["id"]
      end
      path = get_mail_path(mail_data)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        f.flock(File::LOCK_EX)
        f.print(mail_data)
        f.fsync
      end
      mailbox_id_path = path + ".mailbox-id"
      File.open(mailbox_id_path, "w") do |f|
        f.flock(File::LOCK_EX)
        f.print(mail_data.properties["mailbox-id"].to_s)
        f.fsync
      end
      time = mail_data.internal_date.to_time
      File.utime(time, time, path)
      @mail_store.index_mail(mail_data, path)
    end

    def get_mail_path(mail)
      relpath = format("mails/%s/%d",
                       mail.internal_date.strftime("%Y/%m/%d"),
                       mail.uid)
      return File.expand_path(relpath, @mail_store.path)
    end

    def status
      @mail_store.open_backend do |backend|
        return backend.mailbox_status(self)
      end
    end

    def uid_search(query)
      @mail_store.open_backend do |backend|
        return backend.uid_search(self, query)
      end
    end

    def uid_search_by_keys(keys)
      @mail_store.open_backend do |backend|
        return backend.uid_search_by_keys(self, keys)
      end
    end

    def fetch(sequence_set)
      @mail_store.open_backend do |backend|
        return backend.fetch(self, sequence_set)
      end
    end

    def uid_fetch(sequence_set)
      @mail_store.open_backend do |backend|
        return backend.uid_fetch(self, sequence_set)
      end
    end

    def get_mail(uid)
      return IndexedMail.new(@config, self, uid, uid)
    end
  end

  class EnvelopeSearchBasedMailbox < SearchBasedMailbox
    def import(mail_data)
      faked_mail_data =
        MailData.new(mail_data.raw_data, mail_data.uid,
                     mail_data.flags, mail_data.internal_date,
                     '', mail_data.properties,
                     mail_data.parsed_mail)
      super(faked_mail_data)
    end

    def save
      unless @mail_store.mailbox_db["mailboxes"].key?(@name)
        @data["id"] = @mail_store.get_next_mailbox_id
        @data["last_peeked_uid"] ||= 0
        @data["query"] = format('mailbox-id = %d', @data["id"])
      end
      super
    end
  end

  class DefaultMailbox < SearchBasedMailbox
    def initialize(mail_store)
      super(mail_store, "DEFAULT", {})
    end

    def import(mail_data)
      if mail_data.properties["x-ml-name"].empty?
        mail_data.properties["mailbox-id"] = 1
      else
        mail_data.properties["mailbox-id"] = 0
      end
      super(mail_data)
    end
  end

  class StaticMailbox < Mailbox
    def initialize(mail_store, name, data)
      super(mail_store, name, data)
      relpath = format("mailboxes/%d/flags.sdbm", data["id"])
      @flags_db_path = File.expand_path(relpath, mail_store.path)
    end

    def save
      unless @mail_store.mailbox_db["mailboxes"].key?(@name)
        @data["id"] = @mail_store.get_next_mailbox_id
        @data["last_peeked_uid"] ||= 0
      end
      super
      FileUtils.mkdir_p(get_mailbox_dir)
    end

    def import(mail_data)
      path = get_mail_path(mail_data)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        f.flock(File::LOCK_EX)
        f.print(mail_data)
        f.fsync
      end
      time = mail_data.internal_date.to_time
      File.utime(time, time, path)
      open_flags_db do |db|
        db[mail_data.uid.to_s] = mail_data.flags
      end
    end

    def get_mail_path(mail)
      return File.expand_path(mail.uid.to_s, get_mailbox_dir)
    end

    def status
      mailbox_status = MailboxStatus.new
      uids = get_uids
      mailbox_status.messages = uids.length
      open_flags_db do |db|
        mailbox_status.unseen = uids.select { |uid|
          !/\\Seen\b/ni.match(db[uid.to_s])
        }.length
      end
      mailbox_status.recent = uids.select { |uid|
        uid > self["last_peeked_uid"]
      }.length
      return mailbox_status
    end

    def uid_search(query)
      return []
    end

    def fetch(sequence_set)
      uids = get_uids
      mails = []
      sequence_set.each do |seq_number|
        case seq_number
        when Range
          first = seq_number.first
          last = seq_number.last == -1 ? uids.length : seq_number.last
          for i in first .. last
            uid = uids[i - 1]
            next if uid.nil?
            mail = StaticMail.new(@config, self, i, uid)
            mails.push(mail)
          end
        else
          uid = uids[seq_number - 1]
          next if uid.nil?
          mail = StaticMail.new(@config, self, seq_number, uid)
          mails.push(mail)
        end
      end
      return mails
    end

    def uid_fetch(sequence_set)
      uids = get_uids
      return uids if uids.empty?
      uid_set = Set.new(uids)
      mails = []
      sequence_set.each do |seq_number|
        case seq_number
        when Range
          first = seq_number.first
          last = seq_number.last == -1 ? uids.last : seq_number.last
          if last > uids.last
            last = uids.last
          end

          for uid in (first..last).to_a & uids
            mail = StaticMail.new(@config, self, uid, uid)
            mails.push(mail)
          end
        else
          next unless uid_set.include?(seq_number)
          mail = StaticMail.new(@config, self, seq_number, seq_number)
          mails.push(mail)
        end
      end
      return mails
    end

    def get_mail(uid)
      return StaticMail.new(@config, self, uid, uid)
    end

    def open_flags_db(&block)
      SDBM.open(@flags_db_path, &block)
    end

    private

    def get_mailbox_dir
      relpath = format("mailboxes/%d", self["id"])
      return File.expand_path(relpath, @mail_store.path)
    end

    def get_uids
      dirpath = File.expand_path(format("mailboxes/%d", self["id"]),
                                 @mail_store.path)
      return Dir.open(dirpath) { |dir|
        dir.grep(/\A\d+\z/).collect { |uid| uid.to_i }.sort
      }
    end
  end
end
