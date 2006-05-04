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

class XimapdMailboxTest < Test::Unit::TestCase
  include XimapdTestMixin

  def test_save
    mail_store = Ximapd::MailStore.new(@config)
    mailbox = Ximapd::Mailbox.new(mail_store, "mailbox-test",
                                  "flags" => "\\Noselect")
    mail_store.mailbox_db.transaction do
      mailbox.save
      mailbox_data = mail_store.mailbox_db["mailboxes"]["mailbox-test"]
      assert_equal("Mailbox", mailbox_data["class"])
      assert_equal("\\Noselect", mailbox_data["flags"])
    end

    mail_store.teardown
  end

  def test_query
    mail_store = Ximapd::MailStore.new(@config)
    mailbox = Ximapd::SearchBasedMailbox.new(mail_store,
                                             "mailbox-test",
                                             "query" => "subject : hello",
                                             "flags" => "\\Noselect")
    q = Ximapd::PropertyPeQuery.new("subject", "hello")
    assert_equal(q, mailbox.query)

    mail_store.teardown
  end
end

# vim: set filetype=ruby expandtab sw=2 :
