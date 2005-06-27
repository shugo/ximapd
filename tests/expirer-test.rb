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

require File.expand_path("test-helper", File.dirname(__FILE__))
require_plugin "expirer"

class XimapdExpirerTest < Test::Unit::TestCase
  include XimapdTestMixin

  def setup
    super
    @mail_store = Ximapd::MailStore.new(@config)
    @mail_store.mailbox_db.transaction do
      mailbox = Ximapd::StaticMailbox.new(@mail_store, "static-mailbox",
                                          "flags" => "")
      mailbox.save
    end

    @mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello world
EOF
    @uid1 = @mail_store.import_mail(@mail1, "static-mailbox", "\\Seen",
                                    Time.mktime(2005, 6, 19, 23, 59, 59))
    @mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: bye
Date: Wed, 30 Mar 2005 19:18:02 +0900

Goodbye world
EOF
    @uid2 = @mail_store.import_mail(@mail2, "static-mailbox", "\\Seen",
                                    Time.mktime(2005, 6, 20, 0, 0, 0))
    @mail3 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: test3
Date: Wed, 30 Mar 2005 19:18:02 +0900

This is test3
EOF
    @uid3 = @mail_store.import_mail(@mail3, "static-mailbox", "")
    @mail_store.mailbox_db.transaction do
      mailbox_data = @mail_store.mailbox_db["mailboxes"]["static-mailbox"]
      mailbox_data["last_peeked_uid"] = @uid3
    end
    @mail4 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: test4
Date: Wed, 30 Mar 2005 19:18:02 +0900

This is test4
EOF
    @uid4 = @mail_store.import_mail(@mail4, "static-mailbox", "")
    @mail5 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: test5
Date: Wed, 30 Mar 2005 19:18:02 +0900

This is test5
EOF
    @uid5 = @mail_store.import_mail(@mail5, "static-mailbox", "")

    config = {
      "limit" => {
        "static-mailbox" => {
          "days" => 7
        }
      }
    }
    @expirer = Ximapd::Expirer.new(config, @mail_store, @config["logger"])
    @mailbox = @mail_store.mailbox_db.transaction(true) {
      @mail_store.get_mailbox("static-mailbox")
    }
  end

  def test_on_idle
    time = Time.mktime(2005, 6, 27, 0, 0, 0)
    Time.replace_now(time) do
      @mail_store.mailbox_db.transaction do
        @expirer.on_idle
      end
    end
    mails = @mailbox.fetch([1..-1])
    assert_equal(4, mails.length)
    assert_equal(@uid2, mails[0].uid)
    assert_equal(@mail2, mails[0].to_s)
    assert_equal(@uid3, mails[1].uid)
    assert_equal(@mail3, mails[1].to_s)
    assert_equal(@uid4, mails[2].uid)
    assert_equal(@mail4, mails[2].to_s)
    assert_equal(@uid5, mails[3].uid)
    assert_equal(@mail5, mails[3].to_s)
  end
end

# vim: set filetype=ruby expandtab sw=2 :
