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
  class Backend
    @@directory = nil

    def self.directory
      return @@directory
    end

    def self.directory=(dir)
      @@directory = dir
    end

    def initialize(mail_store)
      @mail_store = mail_store
      @config = @mail_store.config
      @mailbox_db = @mail_store.mailbox_db
      @path = @mail_store.path
      @index = nil
      @index_path = File.expand_path("index", @path)
    end

    def setup
      raise SubclassResponsibilityError.new
    end

    def standby
      raise SubclassResponsibilityError.new
    end

    def relax
      raise SubclassResponsibilityError.new
    end

    def open(*args)
      raise SubclassResponsibilityError.new
    end

    def close
      raise SubclassResponsibilityError.new
    end

    def register(mail_data, filename)
      raise SubclassResponsibilityError.new
    end

    def get_flags(uid, item_id, item_obj)
      raise SubclassResponsibilityError.new
    end

    def set_flags(uid, item_id, item_obj, flags)
      raise SubclassResponsibilityError.new
    end

    def delete_flags(uid, item_id, item_obj)
      raise SubclassResponsibilityError.new
    end

    def delete(uid, item_id)
      raise SubclassResponsibilityError.new
    end

    def fetch(mailbox, sequence_set)
      raise SubclassResponsibilityError.new
    end

    def uid_fetch(mailbox, sequence_set)
      raise SubclassResponsibilityError.new
    end

    def mailbox_status(mailbox)
      raise SubclassResponsibilityError.new
    end

    def query(mailbox, query)
      raise SubclassResponsibilityError.new
    end

    def uid_search(mailbox, query)
      raise SubclassResponsibilityError.new
    end

    def uid_search_by_keys(mailbox, keys)
      raise SubclassResponsibilityError.new
    end

    def rebuild_index(*args)
      raise SubclassResponsibilityError.new
    end

    def get_old_flags(uid)
      raise SubclassResponsibilityError.new
    end

    def try_query(query)
      raise SubclassResponsibilityError.new
    end
  end
end
