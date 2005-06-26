# $Id: mail-store-test.rb 145 2005-06-26 00:41:06Z shugo $
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

class XimapdStaticMailboxTest < Test::Unit::TestCase
  include XimapdTestMixin

  def setup
    super
    @mail_store = Ximapd::MailStore.new(@config)
    @mail_store.mailbox_db.transaction do
      @mail_store.mailbox_db["status"]["last_mailbox_id"] += 1
      mailbox_id = @mail_store.mailbox_db["status"]["last_mailbox_id"]
      @mail_store.mailbox_db["mailboxes"]["static-mailbox"] = {
        "id" => mailbox_id,
        "class" => "StaticMailbox",
        "flags" => "",
        "last_peeked_uid" => 0
      }
      FileUtils.mkdir_p(File.expand_path("mailboxes/#{mailbox_id}",
                                         @config["data_dir"]))
    end
  end

  def test_status
    mailbox = @mail_store.get_mailbox("static-mailbox")
    status = mailbox.status
    assert_equal(0, status.messages)
    assert_equal(0, status.unseen)
    assert_equal(0, status.recent)

    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello world
EOF
    uid2 = @mail_store.import_mail(mail1, "static-mailbox", "\\Seen")
    @mail_store.mailbox_db.transaction do
      mailbox_data = @mail_store.mailbox_db["mailboxes"]["static-mailbox"]
      mailbox_data["last_peeked_uid"] = uid2
    end

    mailbox = @mail_store.get_mailbox("static-mailbox")
    status = mailbox.status
    assert_equal(1, status.messages)
    assert_equal(0, status.unseen)
    assert_equal(0, status.recent)

    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: bye
Date: Wed, 30 Mar 2005 19:21:09 +0900

Goodbye world
EOF
    @mail_store.import_mail(mail1, "static-mailbox", "")

    mailbox = @mail_store.get_mailbox("static-mailbox")
    status = mailbox.status
    assert_equal(2, status.messages)
    assert_equal(1, status.unseen)
    assert_equal(1, status.recent)
  end
end

# vim: set filetype=ruby expandtab sw=2 :
