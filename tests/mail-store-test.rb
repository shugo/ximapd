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

class XimapdMailStoreTest < Test::Unit::TestCase
  include XimapdTestMixin

  def test_backend_class
    mail_store = Ximapd::MailStore.new(@config)
    case @config["backend"]
    when "Rast"
      expect = "Ximapd::RastBackend"
    when "HyperEstraier"
      expect = "Ximapd::HyperEstraierBackend"
    else
      expect = nil
    end
    assert_equal(expect, mail_store.backend_class.to_s)
  end

  def test_import_mail
    mail_store = Ximapd::MailStore.new(@config)
    mail_store.create_mailbox("test")
    mail1 = <<EOF.gsub(/\n/, "\r\n")
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
    uid1 = mail_store.import_mail(mail1)
    inbox = mail_store.mailbox_db.transaction {
      mail_store.get_mailbox("INBOX")
    }
    mails = inbox.uid_fetch([uid1])
    assert_equal(1, mails.length)
    m = mails[0]
    assert_equal(uid1, m.uid)
    assert_equal(mail1.sub(/\AFrom.*\r\n/, ""), m.to_s)

    mail2 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: shugo@ruby-lang.org (Shugo Maeda
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid2 = mail_store.import_mail(mail2)
    assert_equal(uid1 + 1, uid2)
    mails = inbox.uid_fetch([uid2])
    assert_equal(1, mails.length)
    m = mails[0]
    assert_equal(uid2, m.uid)
    assert_equal(mail2.sub(/\AFrom.*\r\n/, ""), m.to_s)

    mail3 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: shugo@ruby-lang.org (Shugo Maeda
Subject: bye
To: Foo <foo@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

Goodbye world
EOF
    uid3 = mail_store.import_mail(mail3, "test")
    assert_equal(uid2 + 1, uid3)
    test_mailbox = mail_store.mailbox_db.transaction {
      mail_store.get_mailbox("test")
    }
    mails = test_mailbox.uid_fetch([uid3])
    assert_equal(1, mails.length)
    m = mails[0]
    assert_equal(uid3, m.uid)
    assert_equal(mail3.sub(/\AFrom.*\r\n/, ""), m.to_s)
  end

  def test_import_mail__ml
    mail_store = Ximapd::MailStore.new(@config)
    mail = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: hello
To: ximapd-ja@qwik.netlab.jp
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII
X-ML-Name: ximapd-ja

Hello world
EOF
    mail_store.import_mail(mail)
    mail_store.mailbox_db.transaction do
      ml = mail_store.mailbox_db["mailing_lists"]["ximapd-ja"]
      assert_equal("ml/ximapd-ja", ml["mailbox"])
    end
  end

  def test_delete_mailbox
    mail_store = Ximapd::MailStore.new(@config)
    mail = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: hello
To: ximapd-ja@qwik.netlab.jp
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII
X-ML-Name: ximapd-ja

Hello world
EOF
    mail_store.import_mail(mail)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: hello
To: ximapd-en@qwik.netlab.jp
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII
X-ML-Name: ximapd-en

Hello world
EOF
    mail_store.import_mail(mail2)
    mail_store.mailbox_db.transaction do
      ml = mail_store.mailbox_db["mailing_lists"]["ximapd-ja"]
      assert_equal("ml/ximapd-ja", ml["mailbox"])
      ml2 = mail_store.mailbox_db["mailing_lists"]["ximapd-en"]
      assert_equal("ml/ximapd-en", ml2["mailbox"])
    end
    mail_store.delete_mailbox("ml/ximapd-ja")
    mail_store.mailbox_db.transaction do
      assert_raise(Ximapd::NoMailboxError) do
        mail_store.get_mailbox("ml/ximapd-ja")
      end
      ml = mail_store.mailbox_db["mailing_lists"]["ximapd-ja"]
      assert_equal(nil, ml)
      ml2 = mail_store.mailbox_db["mailing_lists"]["ximapd-en"]
      assert_equal("ml/ximapd-en", ml2["mailbox"])
    end
  end

  def test_rename_mailbox
    mail_store = Ximapd::MailStore.new(@config)
    mail = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: hello
To: ximapd-ja@qwik.netlab.jp
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII
X-ML-Name: ximapd-ja

Hello world
EOF
    mail_store.import_mail(mail)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: hello
To: ximapd-en@qwik.netlab.jp
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII
X-ML-Name: ximapd-en

Hello world
EOF
    mail_store.import_mail(mail2)
    mail_store.mailbox_db.transaction do
      ml = mail_store.mailbox_db["mailing_lists"]["ximapd-ja"]
      assert_equal("ml/ximapd-ja", ml["mailbox"])
      ml2 = mail_store.mailbox_db["mailing_lists"]["ximapd-en"]
      assert_equal("ml/ximapd-en", ml2["mailbox"])
    end
    mail_store.rename_mailbox("ml/ximapd-ja", "ximapd/ja")
    mail_store.mailbox_db.transaction do
      assert_raise(Ximapd::NoMailboxError) do
        mail_store.get_mailbox("ml/ximapd-ja")
      end
      mbox = mail_store.get_mailbox("ximapd/ja")
      assert_equal("ximapd-ja", mbox["list_id"])
      ml = mail_store.mailbox_db["mailing_lists"]["ximapd-ja"]
      assert_equal("ximapd/ja", ml["mailbox"])
      ml2 = mail_store.mailbox_db["mailing_lists"]["ximapd-en"]
      assert_equal("ml/ximapd-en", ml2["mailbox"])
    end
  end

  def test_rebuild_index
    mail_store = Ximapd::MailStore.new(@config)
    mail_store.mailbox_db.transaction do
      mailing_lists = mail_store.mailbox_db["mailing_lists"]
      mailing_lists["foo"] = {
        "creater_uid" => 1,
        "mailbox" => "ml/foo"
      }
      mailing_lists["bar"] = {
        "creater_uid" => 1,
        "mailbox" => "bar"
      }
      mailboxes = mail_store.mailbox_db["mailboxes"]
      mailboxes["ml/foo"] = {
        "flags" => "",
        "last_peeked_uid" => 1,
        "query" => 'x-ml-name = "foo"',
        "list_id" => "foo"
      }
      mailboxes["bar"] = {
        "flags" => "",
        "last_peeked_uid" => 1,
        "query" => 'x-ml-name = "bar"',
        "list_id" => "bar"
      }
    end
    mail_store.create_mailbox("test")
    mail1 = <<EOF.gsub(/\n/, "\r\n")
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
    uid1 = mail_store.import_mail(mail1)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: shugo@ruby-lang.org (Shugo Maeda
Subject: Bye
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

Goodbye world
EOF
    uid2 = mail_store.import_mail(mail2)
    mail3 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: shugo@ruby-lang.org (Shugo Maeda
Subject: bye
To: Foo <foo@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

Goodbye world
EOF
    uid3 = mail_store.import_mail(mail3, "test")
    mail4 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
X-ML-Name: foo
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid4 = mail_store.import_mail(mail4)
    mail5 = <<EOF.gsub(/\n/, "\r\n")
From foobar@ruby-lang.org  Sat Apr  2 00:07:54 2005
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
X-ML-Name: bar
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid5 = mail_store.import_mail(mail5)

    @config["delete_ml_mailboxes"] = true
    mail_store.rebuild_index

    status = mail_store.get_mailbox_status("INBOX", true)
    assert_equal(2, status.uidvalidity)
    inbox = nil
    foo = nil
    bar = nil
    mail_store.mailbox_db.transaction do
      mailing_lists = mail_store.mailbox_db["mailing_lists"]
      assert_equal("ml/foo", mailing_lists["foo"]["mailbox"])
      assert_equal("ml/bar", mailing_lists["bar"]["mailbox"])
      mailboxes = mail_store.mailbox_db["mailboxes"]
      inbox = mail_store.get_mailbox("INBOX")
      foo = mail_store.get_mailbox("ml/foo")
      assert_equal("foo", foo["list_id"])
      bar = mail_store.get_mailbox("ml/bar")
      assert_equal("bar", bar["list_id"])
      assert_raise(Ximapd::NoMailboxError) do
        mail_store.get_mailbox("bar")
      end
    end
    uids = inbox.uid_search({"main" => "hello"})
    assert_equal([uid1], uids)
    uids = inbox.uid_search({"main" => "bye"})
    assert_equal([uid2], uids)
    case @config["backend"]
    when "Rast"
      uids = inbox.uid_search({"main" => "from : shugo"})
      assert_equal([uid1, uid2], uids)
    when "HyperEstraier"
      uids = inbox.uid_search({"main" => "", "sub" => "from STRINC shugo"})
      assert_equal([uid1, uid2], uids)
    else
      raise
    end
    uids = foo.uid_search({"main" => "hello"})
    assert_equal([uid4], uids)
    uids = bar.uid_search({"main" => "hello"})
    assert_equal([uid5], uids)
    test_mailbox = mail_store.mailbox_db.transaction {
      mail_store.get_mailbox("test")
    }
    mails = test_mailbox.uid_fetch([uid3])
    assert_equal(1, mails.length)
    m = mails[0]
    assert_equal(uid3, m.uid)
    assert_equal(mail3.sub(/\AFrom.*\r\n/, ""), m.to_s)
  end
end

# vim: set filetype=ruby expandtab sw=2 :
