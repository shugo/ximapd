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

class SpamFilter < Plugin
  def init_plugin
    begin
      @mail_store.get_mailbox("spam")
    rescue NoMailboxError
      mailbox_class = Ximapd.const_get(@config["spam_mailbox_class"] ||
                                       "StaticMailbox")
      mailbox = mailbox_class.new(@mail_store, "spam", "flags" => "")
      mailbox.save
      @logger.info("mailbox created: spam")
    end
  end

  def filter(mail)
    IO.popen("bsfilter", "w") do |bsfilter|
      bsfilter.print(mail)
    end
    if $?.exitstatus == 0
      @logger.debug("spam: uid=#{mail.uid}")
      return "spam"
    else
      @logger.debug("clean: uid=#{mail.uid}")
      return nil
    end
  end

  def on_copied(src_mail, dest_mail)
    if dest_mail.mailbox.name == "spam"
      learn_spam(src_mail)
    end
  end

  def on_store(mail, att, flags)
    if mail.mailbox.name == "spam"
      if /\\Deleted\b/in.match(mail.flags)
        if !/\\Deleted\b/in.match(flags)
          learn_spam(mail)
        end
      else
        if /\\Deleted\b/in.match(flags)
          learn_clean(mail)
        end
      end
    end
    return flags
  end

  private

  def learn_spam(mail)
    learn(mail, "spam")
  end

  def learn_clean(mail)
    learn(mail, "clean")
  end

  def learn(mail, type)
    @logger.info("added to the #{type} token database: uid=#{mail.uid}")
    IO.popen("bsfilter --add-#{type} --update", "w") do |bsfilter|
      bsfilter.print(mail)
    end
  end
end
