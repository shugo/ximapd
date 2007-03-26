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

class XimapdMailTest < Test::Unit::TestCase
  include XimapdTestMixin

  def test_internal_date
    mail_store = Ximapd::MailStore.new(@config)
    s = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    date = DateTime.new(1975, 11, 24, 12, 0, 0)
    uid = mail_store.import_mail(s, "INBOX", "", date)
    inbox = mail_store.mailbox_db.transaction {
      mail_store.get_mailbox("INBOX")
    }
    mail = inbox.uid_fetch([uid]).first
    assert_equal(date, mail.internal_date)
    mail_store.teardown
  end
end

# vim: set filetype=ruby expandtab sw=2 :
