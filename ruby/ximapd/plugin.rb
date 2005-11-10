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
  class Plugin
    @@directories = nil
    @@loaded = false

    def self.directories=(dirs)
      @@directories = dirs
    end

    def self.create_plugins(config, mail_store)
      return Plugins.new([]) unless config.key?("plugins")
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
      plugins = config["plugins"].collect { |plugin|
        Ximapd.const_get(plugin["name"]).new(plugin, mail_store,
                                             config["logger"])
      }
      return Plugins.new(plugins)
    end

    def initialize(config, mail_store, logger)
      @config = config
      @mail_store = mail_store
      @logger = logger
      init_plugin
    end

    def init_plugin
    end

    def on_store(mail, att, flags)
      return flags
    end

    def on_copy(src_mail, dest_mailbox)
    end

    def on_copied(src_mail, dest_mail)
    end

    def on_delete_mail(mail)
    end

    def on_idle
    end

    def filter(mail)
      return nil
    end

    def translate_mailbox_query(mailbox, query)
      return query
    end
  end

  class Plugins < Array
    def fire_event(name, *args)
      for plugin in self
        plugin.send(name, *args)
      end
    end
  end
end
