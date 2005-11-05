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

require "sdbm"
require "digest/sha1"

class DupCheckFilter < Plugin
  def init_plugin
    @db_path = File.expand_path("dupcheck.sdbm", @mail_store.path)
  end

  def filter(mail)
    open_db do |db|
      key = get_key(mail)
      @logger.debug("key: #{key}")
      uid = db[key]
      if uid
        @logger.warn("rejected duplicated mail: uid=#{mail.uid}, old_uid=#{uid}")
        return "REJECT"
      else
        db[key] = mail.uid.to_s
        return nil
      end
    end
  end

  def on_delete_mail(mail)
    open_db do |db|
      key = get_key(mail)
      db.delete(key)
      @logger.debug("deleted from duplication check db: uid=#{mail.uid}")
    end
  end

  private

  def open_db
    db = SDBM.open(@db_path)
    begin
      yield(db)
    ensure
      db.close
    end
  end

  def get_key(mail)
    return Digest::SHA1.hexdigest(mail.to_s) + ":" +
      mail.header["message-id"].to_s
  end
end
