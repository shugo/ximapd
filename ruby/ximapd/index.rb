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
  INDEX_ENGINES = {} # { "Name" => [IndexClass, "library-name", "library-version"], ...}

  class AbstractIndex
    class << self
      def make_list_query(list_name)
        raise ScriptError.new("subclass must override this method")
      end

      def make_default_query(mailbox_id)
        raise ScriptError.new("subclass must override this method")
      end

      def make_query(mailbox_name)
        raise ScriptError.new("subclass must override this method")
      end
    end

    def initialize(mail_store)
      @mail_store = mail_store
      @config = @mail_store.config
      @mailbox_db = @mail_store.mailbox_db
      @path = @mail_store.path
      @index = nil
      @index_path = File.expand_path("index", @path)
    end
    private :initialize

    def setup
      raise ScriptError.new("subclass must override this method")
    end

    def standby
      raise ScriptError.new("subclass must override this method")
    end

    def relax
      raise ScriptError.new("subclass must override this method")
    end

    def open(*args)
      raise ScriptError.new("subclass must override this method")
    end

    def close
      raise ScriptError.new("subclass must override this method")
    end

    def register(mail_data, filename)
      raise ScriptError.new("subclass must override this method")
    end

    def get_flags(uid, item_id, item_obj)
      raise ScriptError.new("subclass must override this method")
    end

    def set_flags(uid, item_id, item_obj, flags)
      raise ScriptError.new("subclass must override this method")
    end

    def delete_flags(uid, item_id, item_obj)
      raise ScriptError.new("subclass must override this method")
    end

    def delete(uid, item_id)
      raise ScriptError.new("subclass must override this method")
    end

    def fetch(mailbox, sequence_set)
      raise ScriptError.new("subclass must override this method")
    end

    def uid_fetch(mailbox, sequence_set)
      raise ScriptError.new("subclass must override this method")
    end

    def mailbox_status(mailbox)
      raise ScriptError.new("subclass must override this method")
    end

    def query(mailbox, query)
      raise ScriptError.new("subclass must override this method")
    end

    def uid_search(mailbox, query)
      raise ScriptError.new("subclass must override this method")
    end

    def uid_search_by_keys(mailbox, keys)
      raise ScriptError.new("subclass must override this method")
    end

    def rebuild_index(*args)
      raise ScriptError.new("subclass must override this method")
    end

    def get_old_flags(uid)
      raise ScriptError.new("subclass must override this method")
    end

    def try_query(query)
      raise ScriptError.new("subclass must override this method")
    end
  end # class AbstractIndex
end
