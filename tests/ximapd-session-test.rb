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

require File.expand_path("ximapd-test-helper", File.dirname(__FILE__))

Ximapd::Session.test = true

class XimapdSessionTest < Test::Unit::TestCase
  def setup
    @tmpdir = mkdtemp("ximapd-test")
    @config = {
      "user" => "foo",
      "password" => "bar",
      "data_dir" => File.expand_path("data", @tmpdir),
      "logger" => NullObject.new
    }
    @challenge_generator =
      Ximapd::AuthenticateCramMD5Command.challenge_generator
    Ximapd::AuthenticateCramMD5Command.challenge_generator = Proc.new {
      "<12345@localhost>"
    }
    #GC.disable # to avoid `BDB::Fatal: BUG : current_env not set'
  end

  def teardown
    #GC.enable
    Ximapd::AuthenticateCramMD5Command.challenge_generator =
      @challenge_generator
    system("rm", "-rf", @tmpdir)
  end

  def test_capability
    sock = SpoofSocket.new(<<EOF)
A001 CAPABILITY\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_match("* CAPABILITY IMAP4REV1 IDLE LOGINDISABLED AUTH=CRAM-MD5\r\n",
                 sock.output.gets)
    assert_equal("A001 OK CAPABILITY completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_noop
    sock = SpoofSocket.new(<<EOF)
A001 NOOP\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 OK NOOP completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_logout
    sock = SpoofSocket.new(<<EOF)
A001 LOGOUT\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_match(/\A\* BYE /, sock.output.gets)
    assert_equal("A001 OK LOGOUT completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::LOGOUT_STATE, session.state)
  end

  def test_authenticate_cram_md5
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::AUTHENTICATED_STATE, session.state)
  end

  def test_login
    sock = SpoofSocket.new(<<EOF)
A001 LOGIN foo bar\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 NO LOGIN failed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::NON_AUTHENTICATED_STATE, session.state)
  end

  def test_select
    sock = SpoofSocket.new(<<EOF)
A001 SELECT INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 SELECT inbox\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n", sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n", sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello world
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid1 = mail_store.import_mail(mail1)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid1 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: bye
Date: Fri, 01 Apr 2005 11:47:10 +0900

Goodbye world
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid2 = mail_store.import_mail(mail2)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)

    mail3 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: [ximapd-users:00001] ximapd-0.0.0 released!
X-ML-Name: ximapd-users
X-Mail-Count: 1
Date: Fri, 01 Apr 2005 11:47:10 +0900

ximapd-0.0.0 is released!
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid3 = mail_store.import_mail(mail3)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 SELECT ml/ximapd-users\r
A004 SELECT foo\r
A005 SELECT ml\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid3 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid3 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("A004 NO no such mailbox\r\n", sock.output.gets)
    assert_equal("A005 NO can't open ml: not a selectable mailbox\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail4 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: support STARTTLS
X-Trac-Project: ximapd
Date: Fri, 01 Apr 2005 11:47:10 +0900

support the STARTTLS command
EOF
    config = @config.dup
    config["ml_header_fields"] = ["X-ML-Name", "X-Trac-Project"]
    mail_store = Ximapd::MailStore.new(config)
    uid4 = mail_store.import_mail(mail4)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT ml/ximapd\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid4 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)
  end

  def test_examine
    sock = SpoofSocket.new(<<EOF)
A001 EXAMINE INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 EXAMINE INBOX\r
A003 EXAMINE inbox\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n", sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n", sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello world
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid1 = mail_store.import_mail(mail1)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 EXAMINE INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid1 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: bye
Date: Fri, 01 Apr 2005 11:47:10 +0900

Goodbye world
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid2 = mail_store.import_mail(mail2)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 EXAMINE INBOX\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail3 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: [ximapd-users:00001] ximapd-0.0.0 released!
X-ML-Name: ximapd-users
X-Mail-Count: 1
Date: Fri, 01 Apr 2005 11:47:10 +0900

ximapd-0.0.0 is released!
EOF
    mail_store = Ximapd::MailStore.new(@config)
    uid3 = mail_store.import_mail(mail3)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 EXAMINE INBOX\r
A003 EXAMINE ml/ximapd-users\r
A004 EXAMINE foo\r
A005 EXAMINE ml\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid3 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid3 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal("A004 NO no such mailbox\r\n", sock.output.gets)
    assert_equal("A005 NO can't open ml: not a selectable mailbox\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)

    mail4 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: support STARTTLS
X-Trac-Project: ximapd
Date: Fri, 01 Apr 2005 11:47:10 +0900

support the STARTTLS command
EOF
    config = @config.dup
    config["ml_header_fields"] = ["X-ML-Name", "X-Trac-Project"]
    mail_store = Ximapd::MailStore.new(config)
    uid4 = mail_store.import_mail(mail4)
    mail_store.close
    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 EXAMINE ml/ximapd\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid4 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-ONLY] EXAMINE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::SELECTED_STATE, session.state)
  end

  def test_create
    sock = SpoofSocket.new(<<EOF)
A001 CREATE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 LIST "" "*"\r
A003 CREATE foo\r
A004 LIST "" "*"\r
A005 SELECT foo\r
A006 CREATE bar/baz/quux\r
A007 LIST "" "*"\r
A008 CREATE queries/ruby\r
A009 CREATE queries/&-\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A002 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A003 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"foo\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A004 OK LIST completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A005 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("A006 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"bar\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"bar/baz\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"bar/baz/quux\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"foo\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A007 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A008 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("A009 NO invalid query\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    mail_store = Ximapd::MailStore.new(@config)
    ruby = mail_store.mailboxes["queries/ruby"]
    assert_equal("ruby", ruby["query"])
    mail_store.close
  end

  def test_delete
    sock = SpoofSocket.new(<<EOF)
A001 DELETE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 LIST "" "*"\r
A003 CREATE foo\r
A004 LIST "" "*"\r
A005 DELETE foo\r
A006 LIST "" "*"\r
A007 DELETE inbox\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A002 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A003 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"foo\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A004 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A005 OK DELETE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A006 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A007 NO can't delete INBOX\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_rename
    sock = SpoofSocket.new(<<EOF)
A001 RENAME foo bar\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 LIST "" "*"\r
A003 CREATE foo\r
A004 LIST "" "*"\r
A005 RENAME foo bar\r
A006 LIST "" "*"\r
A007 RENAME bar baz/quux/quuux\r
A008 LIST "" "*"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A002 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A003 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"foo\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A004 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A005 OK RENAME completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"bar\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A006 OK LIST completed\r\n", sock.output.gets)
    assert_equal("A007 OK RENAME completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"baz\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"baz/quux\"\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"baz/quux/quuux\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A008 OK LIST completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 CREATE queries/ruby\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 OK CREATE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    mail_store = Ximapd::MailStore.new(@config)
    ruby = mail_store.mailboxes["queries/ruby"]
    assert_equal("ruby", ruby["query"])
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 RENAME queries/ruby ruby\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 OK RENAME completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    mail_store = Ximapd::MailStore.new(@config)
    ruby = mail_store.mailboxes["ruby"]
    assert_equal("ruby", ruby["query"])
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 RENAME ruby queries/&-\r
A003 RENAME ruby queries/perl\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 NO invalid query\r\n", sock.output.gets)
    assert_equal("A003 OK RENAME completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    mail_store = Ximapd::MailStore.new(@config)
    perl = mail_store.mailboxes["queries/perl"]
    assert_equal("perl", perl["query"])
    mail_store.close
  end

  def test_subscribe
    sock = SpoofSocket.new(<<EOF)
A001 SUBSCRIBE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SUBSCRIBE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 OK SUBSCRIBE completed\r\n", sock.output.gets)
  end

  def test_unsubscribe
    sock = SpoofSocket.new(<<EOF)
A001 UNSUBSCRIBE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UNSUBSCRIBE foo\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 OK UNSUBSCRIBE completed\r\n", sock.output.gets)
  end

  def test_list
    sock = SpoofSocket.new(<<EOF)
A001 LIST "" ""\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 LIST "" ""\r
A003 LIST "" *\r
A004 LIST "" %\r
A005 LIST "" "INBOX"\r
A006 LIST "" "InBox"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"\"\r\n", sock.output.gets)
    assert_equal("A002 OK LIST completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A003 OK LIST completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LIST (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A004 OK LIST completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("A005 OK LIST completed\r\n", sock.output.gets)
    assert_equal("* LIST () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("A006 OK LIST completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_lsub
    sock = SpoofSocket.new(<<EOF)
A001 LSUB "" ""\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 LSUB "" ""\r
A003 LSUB "" "*"\r
A004 LSUB "" "%"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* LSUB (\\Noselect) \"/\" \"\"\r\n", sock.output.gets)
    assert_equal("A002 OK LSUB completed\r\n", sock.output.gets)
    assert_equal("* LSUB () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LSUB (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LSUB (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A003 OK LSUB completed\r\n", sock.output.gets)
    assert_equal("* LSUB () \"/\" \"INBOX\"\r\n", sock.output.gets)
    assert_equal("* LSUB (\\Noselect) \"/\" \"ml\"\r\n", sock.output.gets)
    assert_equal("* LSUB (\\Noselect) \"/\" \"queries\"\r\n", sock.output.gets)
    assert_equal("A004 OK LSUB completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_status
    mail_store = Ximapd::MailStore.new(@config)
    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: ruby-list@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello, world
EOF
    uid1 = mail_store.import_mail(mail1)
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 STATUS "INBOX" (MESSAGES UNSEEN UIDNEXT)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 STATUS "INBOX" (MESSAGES UNSEEN UIDNEXT)\r
A003 SELECT "INBOX"\r
A004 UID STORE #{uid1} FLAGS (\\Seen)\r
A005 STATUS "INBOX" (MESSAGES UNSEEN UIDNEXT)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* STATUS \"INBOX\" (MESSAGES 1 UNSEEN 1 UIDNEXT 2)\r\n",
                 sock.output.gets)
    assert_equal("A002 OK STATUS completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 2] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (FLAGS (\\Recent \\Seen))\r\n", sock.output.gets)
    assert_equal("A004 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* STATUS \"INBOX\" (MESSAGES 1 UNSEEN 0 UIDNEXT 2)\r\n",
                 sock.output.gets)
    assert_equal("A005 OK STATUS completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_append
    mail = <<EOF
Date: Mon, 7 Feb 1994 21:52:25 -0800 (PST)\r
From: Fred Foobar <foobar@Blurdybloop.COM>\r
Subject: afternoon meeting\r
To: mooch@owatagu.siam.edu\r
Message-Id: <B27397-0100000@Blurdybloop.COM>\r
MIME-Version: 1.0\r
Content-Type: TEXT/PLAIN; CHARSET=US-ASCII\r
\r
Hello Joe, do you think we can meet at 3:30 tomorrow?\r
EOF

    sock = SpoofSocket.new(<<EOF)
A001 APPEND INBOX {#{mail.length}}\r
#{mail}\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ Ready for additional command text\r\n",
                 sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 APPEND INBOX {#{mail.length}}\r
#{mail}\r
A003 SELECT INBOX\r
A004 FETCH 1 (BODY[] FLAGS)\r
A005 CREATE foo\r
A006 APPEND foo (\\Seen) {#{mail.length}}\r
#{mail}\r
A007 SELECT foo\r
A008 FETCH 1 (BODY[] FLAGS)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("+ Ready for additional command text\r\n",
                 sock.output.gets)
    assert_equal("A002 OK APPEND completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 2] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A003 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (BODY[] {#{mail.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail, sock.output.read(mail.length))
    # TODO: remove duplicate FLAGS
    # assert_equal(" FLAGS (\\Seen))\r\n", sock.output.gets)
    assert_equal(" FLAGS (\\Seen) FLAGS (\\Recent \\Seen))\r\n",
                 sock.output.gets)
    assert_equal("A004 OK FETCH completed\r\n", sock.output.gets)
    assert_equal("A005 OK CREATE completed\r\n", sock.output.gets)
    assert_equal("+ Ready for additional command text\r\n",
                 sock.output.gets)
    assert_equal("A006 OK APPEND completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 3] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A007 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (BODY[] {#{mail.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail, sock.output.read(mail.length))
    assert_equal(" FLAGS (\\Recent \\Seen))\r\n", sock.output.gets)
    assert_equal("A008 OK FETCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_idle
    sock = SpoofSocket.new(<<EOF)
A001 IDLE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 IDLE\r
DONE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("+ Waiting for DONE\r\n", sock.output.gets)
    assert_equal("A002 OK IDLE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_check
    sock = SpoofSocket.new(<<EOF)
A001 UID CHECK\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID CHECK\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 CHECK\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("A003 OK CHECK completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_close
    sock = SpoofSocket.new(<<EOF)
A001 UID CLOSE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID CLOSE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 CLOSE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 0 EXISTS\r\n", sock.output.gets)
    assert_equal("* 0 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 1] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("A003 OK CLOSE completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
    assert_equal(Ximapd::AUTHENTICATED_STATE, session.state)
  end

  def test_expunge
    mail_store = Ximapd::MailStore.new(@config)
    hello_mail = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: foo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900
X-Mail-Count: 12345

hello, Foo
EOF
    bye_mail = hello_mail.gsub(/hello/, "bye").gsub(/12345/, "54321")
    10.times do |i|
      if [2, 3, 4, 7].include?(i + 1)
        mail = bye_mail
      else
        mail = hello_mail
      end
      mail_store.import_mail(mail)
    end
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 UID EXPUNGE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID EXPUNGE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 UID SEARCH HEADER SUBJECT bye\r
A004 EXPUNGE\r
A005 UID SEARCH HEADER SUBJECT bye\r
A006 UID STORE 2:4,7 +FLAGS.SILENT (\\Deleted)\r
A007 EXPUNGE\r
A008 UID SEARCH HEADER SUBJECT bye\r
A009 UID SEARCH HEADER SUBJECT hello\r
A010 UID SEARCH HEADER "X-Mail-Count" "12345"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 10 EXISTS\r\n", sock.output.gets)
    assert_equal("* 10 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT 11] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 2 3 4 7\r\n", sock.output.gets)
    assert_equal("A003 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("A004 OK EXPUNGE completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 2 3 4 7\r\n", sock.output.gets)
    assert_equal("A005 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("A006 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 7 EXPUNGE\r\n", sock.output.gets)
    assert_equal("* 4 EXPUNGE\r\n", sock.output.gets)
    assert_equal("* 3 EXPUNGE\r\n", sock.output.gets)
    assert_equal("* 2 EXPUNGE\r\n", sock.output.gets)
    assert_equal("A007 OK EXPUNGE completed\r\n", sock.output.gets)
    assert_equal("* SEARCH\r\n", sock.output.gets)
    assert_equal("A008 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 1 5 6 8 9 10\r\n", sock.output.gets)
    assert_equal("A009 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 1 5 6 8 9 10\r\n", sock.output.gets)
    assert_equal("A010 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_uid_search
    mail_store = Ximapd::MailStore.new(@config)
    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: ruby-list@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello, world
EOF
    uid1 = mail_store.import_mail(mail1)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: foo@ruby-lang.org
To: ruby-list@ruby-lang.org
Subject: bye
Date: Fri, 01 Apr 2005 12:51:06 +0900

Goodbye, world
EOF
    uid2 = mail_store.import_mail(mail2)
    mail3 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: foo@ruby-lang.org
Subject: hello
Date: Sun, 03 Apr 2005 03:06:39 +0900

Hello, foo
EOF
    uid3 = mail_store.import_mail(mail3)
    mail4 = Iconv.conv("iso-2022-jp", "utf-8", <<EOF).gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: foo@ruby-lang.org
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
Date: Sun, 03 Apr 2005 03:06:39 +0900
Content-Type: text/plain; charset=iso-2022-jp

こんにちは、みなさん
EOF
    uid4 = mail_store.import_mail(mail4)
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 UID SEARCH BODY "hello world"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID SEARCH BODY "hello world"\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 UID SEARCH BODY hello\r
A004 UID SEARCH CHARSET US-ASCII BODY hello\r
A005 UID SEARCH BODY "hello world"\r
A006 UID SEARCH BODY "\\"hello world\\""\r
A007 UID SEARCH BODY "\\"hello, world\\""\r
A008 UID SEARCH HEADER SUBJECT hello\r
A009 UID STORE #{uid1} FLAGS (\\Seen)\r
A010 UID SEARCH BODY hello SEEN\r
A011 UID SEARCH BODY hello UNSEEN\r
A012 UID SEARCH CHARSET UTF-8 HEADER SUBJECT "こんにちは"\r
A013 UID SEARCH CHARSET UTF-8 BODY "みなさん"\r
A014 UID SEARCH BODY hello NOT SEEN\r
A015 UID SEARCH 2\r
A016 UID SEARCH 2:3\r
A017 UID SEARCH 2:*\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 4 EXISTS\r\n", sock.output.gets)
    assert_equal("* 4 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid4 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1} #{uid3}\r\n", sock.output.gets)
    assert_equal("A003 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1} #{uid3}\r\n", sock.output.gets)
    assert_equal("A004 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1}\r\n", sock.output.gets)
    assert_equal("A005 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH\r\n", sock.output.gets)
    assert_equal("A006 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1}\r\n", sock.output.gets)
    assert_equal("A007 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1} #{uid3}\r\n", sock.output.gets)
    assert_equal("A008 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (FLAGS (\\Recent \\Seen))\r\n", sock.output.gets)
    assert_equal("A009 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid1}\r\n", sock.output.gets)
    assert_equal("A010 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid3}\r\n", sock.output.gets)
    assert_equal("A011 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid4}\r\n", sock.output.gets)
    assert_equal("A012 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid4}\r\n", sock.output.gets)
    assert_equal("A013 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH #{uid3}\r\n", sock.output.gets)
    assert_equal("A014 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 2\r\n",
                 sock.output.gets)
    assert_equal("A015 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 2 3\r\n",
                 sock.output.gets)
    assert_equal("A016 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal("* SEARCH 2 3 4\r\n",
                 sock.output.gets)
    assert_equal("A017 OK UID SEARCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_fetch
    mail_store = Ximapd::MailStore.new(@config)
    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
To: foo@ruby-lang.org,
        bar@ruby-lang.org,
	baz@ruby-lang.org
Date: Wed, 30 Mar 2005 17:34:46 +0900
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid1 = mail_store.import_mail(mail1)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
To: ruby-list@ruby-lang.org
X-ML-Name: ruby-list
Date: Sat, 09 Apr 2005 00:54:59 +0900
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid2 = mail_store.import_mail(mail2)
    mail3 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: bye
To: foo@ruby-lang.org,
Date: Sat, 09 Apr 2005 00:55:31 +0900
Content-Type: text/plain; charset=US-ASCII

Hello world
EOF
    uid3 = mail_store.import_mail(mail3)
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 FETCH 1:* (UID FLAGS RFC822.SIZE)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 FETCH 1:* (UID FLAGS RFC822.SIZE)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 FETCH 1:* (UID FLAGS RFC822.SIZE)\r
A004 FETCH 1,2 (UID FLAGS RFC822.SIZE)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 2 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid3 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID #{uid1} FLAGS (\\Recent) RFC822.SIZE #{mail1.length})\r\n",
                 sock.output.gets)
    assert_equal("* 2 FETCH (UID #{uid3} FLAGS (\\Recent) RFC822.SIZE #{mail3.length})\r\n",
                 sock.output.gets)
    assert_equal("A003 OK FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID #{uid1} FLAGS (\\Recent) RFC822.SIZE #{mail1.length})\r\n",
                 sock.output.gets)
    assert_equal("* 2 FETCH (UID #{uid3} FLAGS (\\Recent) RFC822.SIZE #{mail3.length})\r\n",
                 sock.output.gets)
    assert_equal("A004 OK FETCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_uid_fetch
    mail_store = Ximapd::MailStore.new(@config)
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
    mail1_without_unix_from = mail1.sub(/\AFrom.*\n/, "")
    mail2= <<EOF.gsub(/\n/, "\r\n")
Message-ID: <4263685A.6090203@ruby-lang.org>
Date: Mon, 18 Apr 2005 16:57:14 +0900
From: Shugo Maeda <shugo@ruby-lang.org>
MIME-Version: 1.0
To: shugo@ruby-lang.org
Subject: hello.txt
Content-Type: multipart/mixed;
 boundary="------------040107050003050408030009"

This is a multi-part message in MIME format.
--------------040107050003050408030009
Content-Type: text/plain; charset=US-ASCII
Content-Transfer-Encoding: 7bit

see hello.txt.


--------------040107050003050408030009
Content-Type: text/plain;
 name="hello.txt"
Content-Transfer-Encoding: base64
Content-Disposition: inline;
 filename="hello.txt"

SGVsbG8gV29ybGQK
--------------040107050003050408030009--
EOF
    uid2 = mail_store.import_mail(mail2)
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 UID FETCH 1 (FLAGS)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID FETCH 1 (FLAGS)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 UID FETCH 1 (UID FLAGS RFC822.SIZE)\r
A004 UID FETCH 1 RFC822.HEADER\r
A005 UID FETCH 1 RFC822\r
A006 UID FETCH 1 BODY\r
A007 UID FETCH 1 BODYSTRUCTURE\r
A008 UID FETCH 1 BODY.PEEK[HEADER.FIELDS (From To)]\r
A009 UID FETCH 1 BODY.PEEK[]\r
A010 UID FETCH 1 BODY[]<5.10>\r
A011 UID FETCH 1 ENVELOPE\r
A012 UID FETCH 1 BODY[1]\r
A013 UID FETCH 1 BODY.PEEK[HEADER]\r
A014 UID FETCH 1 INTERNALDATE\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 2 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 FLAGS (\\Recent) RFC822.SIZE #{mail1_without_unix_from.length})\r\n",
                 sock.output.gets)
    assert_equal("A003 OK UID FETCH completed\r\n", sock.output.gets)
    header = <<EOF.gsub(/\n/, "\r\n")
Date: Wed, 30 Mar 2005 17:34:46 +0900
Message-ID: <41ECC569.8000603@ruby-lang.org>
From: Shugo Maeda <shugo@ruby-lang.org>
Subject: =?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org
Cc: Baz <"baz.."@ruby-lang.org>
In-Reply-To: <41C448BF.7080605@ruby-lang.org>
Content-Type: text/plain; charset=US-ASCII

EOF
    assert_equal("* 1 FETCH (UID 1 RFC822.HEADER {#{header.length}}\r\n",
                 sock.output.gets)
    assert_equal(header, sock.output.read(header.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A004 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 RFC822 {#{mail1_without_unix_from.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail1_without_unix_from,
                 sock.output.read(mail1_without_unix_from.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A005 OK UID FETCH completed\r\n", sock.output.gets)
    body = <<EOF.gsub(/\n/, "\r\n")
Hello world
EOF
    assert_equal("* 1 FETCH (UID 1 BODY (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"US-ASCII\") NIL NIL \"7BIT\" #{body.length} #{body.to_a.length}))\r\n",
                 sock.output.gets)
    assert_equal("A006 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"US-ASCII\") NIL NIL \"7BIT\" #{body.length} #{body.to_a.length}))\r\n",
                 sock.output.gets)
    assert_equal("A007 OK UID FETCH completed\r\n", sock.output.gets)
    header_fields = <<EOF.gsub(/\n/, "\r\n")
From: Shugo Maeda <shugo@ruby-lang.org>
To: Foo <foo@ruby-lang.org>,
        bar@ruby-lang.org

EOF
    assert_equal("* 1 FETCH (UID 1 BODY[HEADER.FIELDS (\"FROM\" \"TO\")] {#{header_fields.length}}\r\n",
                 sock.output.gets)
    assert_equal(header_fields, sock.output.read(header_fields.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A008 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 BODY[] {#{mail1_without_unix_from.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail1_without_unix_from,
                 sock.output.read(mail1_without_unix_from.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A009 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 BODY[]<5> {10}\r\n",
                 sock.output.gets)
    assert_equal(mail1_without_unix_from[5, 10], sock.output.read(10))
    assert_equal(" FLAGS (\\Seen))\r\n", sock.output.gets)
    assert_equal("A010 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 ENVELOPE (\"Wed, 30 Mar 2005 17:34:46 +0900\" \"=?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?=\" ((\"Shugo Maeda\" NIL \"shugo\" \"ruby-lang.org\")) ((\"Shugo Maeda\" NIL \"shugo\" \"ruby-lang.org\")) ((\"Shugo Maeda\" NIL \"shugo\" \"ruby-lang.org\")) ((\"Foo\" NIL \"foo\" \"ruby-lang.org\") (NIL NIL \"bar\" \"ruby-lang.org\")) ((\"Baz\" NIL \"baz..\" \"ruby-lang.org\")) NIL \"<41C448BF.7080605@ruby-lang.org>\" \"<41ECC569.8000603@ruby-lang.org>\"))\r\n",
                 sock.output.gets)
    assert_equal("A011 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 BODY[1] {#{mail1_without_unix_from.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail1_without_unix_from,
                 sock.output.read(mail1_without_unix_from.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A012 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 BODY[HEADER] {#{header.length}}\r\n",
                 sock.output.gets)
    assert_equal(header, sock.output.read(header.length))
    assert_equal(")\r\n", sock.output.gets)
    assert_equal("A013 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 INTERNALDATE \"02-Apr-2005 00:07:54 +0900\")\r\n",
                 sock.output.gets)
    assert_equal("A014 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_uid_store
    mail_store = Ximapd::MailStore.new(@config)
    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello world
EOF
    uid1 = mail_store.import_mail(mail1)
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 UID STORE 1 FLAGS (\\Seen NonJunk)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID STORE 1 FLAGS (\\Seen NonJunk)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 UID STORE 1 FLAGS (\\Seen NonJunk)\r
A004 UID STORE 1 +FLAGS (\\Deleted)\r
A005 UID STORE 1 -FLAGS (NonJunk)\r
A006 UID STORE 1 FLAGS.SILENT (\\Seen NonJunk)\r
A007 UID FETCH 1 (FLAGS)\r
A008 UID STORE 1 +FLAGS.SILENT (\\Deleted)\r
A009 UID FETCH 1 (FLAGS)\r
A010 UID STORE 1 -FLAGS.SILENT (NonJunk)\r
A011 UID FETCH 1 (FLAGS)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 1 EXISTS\r\n", sock.output.gets)
    assert_equal("* 1 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid1 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (FLAGS (\\Recent \\Seen NonJunk))\r\n",
                 sock.output.gets)
    assert_equal("A003 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (FLAGS (\\Recent \\Seen NonJunk \\Deleted))\r\n",
                 sock.output.gets)
    assert_equal("A004 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (FLAGS (\\Recent \\Seen \\Deleted))\r\n",
                 sock.output.gets)
    assert_equal("A005 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("A006 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 FLAGS (\\Recent \\Seen NonJunk))\r\n",
                 sock.output.gets)
    assert_equal("A007 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("A008 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 FLAGS (\\Recent \\Seen NonJunk \\Deleted))\r\n",
                 sock.output.gets)
    assert_equal("A009 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal("A010 OK UID STORE completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID 1 FLAGS (\\Recent \\Seen \\Deleted))\r\n",
                 sock.output.gets)
    assert_equal("A011 OK UID FETCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  def test_uid_copy
    mail_store = Ximapd::MailStore.new(@config)
    mail1 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: foo@ruby-lang.org
Subject: hello
Date: Wed, 30 Mar 2005 17:34:46 +0900

Hello, Foo
EOF
    uid1 = mail_store.import_mail(mail1)
    mail2 = <<EOF.gsub(/\n/, "\r\n")
From: shugo@ruby-lang.org
To: bar@ruby-lang.org
Subject: hello
Date: Sat, 09 Apr 2005 00:54:59 +0900
Content-Type: text/plain; charset=US-ASCII

Hello, Bar
EOF
    uid2 = mail_store.import_mail(mail2)
    mail_store.create_mailbox("Trash")
    mail_store.close

    sock = SpoofSocket.new(<<EOF)
A001 UID COPY 1:2 Trash\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("A001 BAD Command unrecognized/login please\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 UID COPY 1:2 Trash\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("A002 BAD Command unrecognized\r\n",
                 sock.output.gets)
    assert_equal(nil, sock.output.gets)

    sock = SpoofSocket.new(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
A002 SELECT INBOX\r
A003 UID COPY 1:2 Trash\r
A004 SELECT Trash\r
A005 FETCH 1:* (UID BODY[] FLAGS)\r
EOF
    session = Ximapd::Session.new(@config, sock)
    session.start
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock.output.gets)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock.output.gets)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 2 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("A003 OK UID COPY completed\r\n", sock.output.gets)
    assert_equal("* 2 EXISTS\r\n", sock.output.gets)
    assert_equal("* 2 RECENT\r\n", sock.output.gets)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock.output.gets)
    assert_equal("* OK [UIDNEXT #{uid2 + 3}] Predicted next UID\r\n",
                 sock.output.gets)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock.output.gets)
    assert_equal("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n",
                 sock.output.gets)
    assert_equal("A004 OK [READ-WRITE] SELECT completed\r\n", sock.output.gets)
    assert_equal("* 1 FETCH (UID #{uid2 + 1} BODY[] {#{mail1.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail1, sock.output.read(mail1.length))
    # TODO: remove duplicate FLAGS
    # assert_equal(" FLAGS (\\Seen))\r\n", sock.output.gets)
    assert_equal(" FLAGS (\\Seen) FLAGS (\\Recent \\Seen))\r\n",
                 sock.output.gets)
    assert_equal("* 2 FETCH (UID #{uid2 + 2} BODY[] {#{mail2.length}}\r\n",
                 sock.output.gets)
    assert_equal(mail2, sock.output.read(mail2.length))
    # TODO: remove duplicate FLAGS
    # assert_equal(" FLAGS (\\Seen))\r\n", sock.output.gets)
    assert_equal(" FLAGS (\\Seen) FLAGS (\\Recent \\Seen))\r\n",
                 sock.output.gets)
    assert_equal("A005 OK FETCH completed\r\n", sock.output.gets)
    assert_equal(nil, sock.output.gets)
  end

  class SpoofSocket
    attr_reader :input, :output

    def initialize(s)
      @input = StringIO.new(s)
      @output = StringIO.new
    end

    [:read, :gets, :getc].each do |mid|
      define_method(mid) do |*args|
        @input.send(mid, *args)
      end
    end

    [:write, :print].each do |mid|
      define_method(mid) do |*args|
        @output.send(mid, *args)
      end
    end

    def peeraddr
      return ["AF_INET", 10143, "localhost", "127.0.0.1"]
    end

    def shutdown
    end

    def close
      @output.rewind
    end
  end
end

# vim: set filetype=ruby expandtab sw=2 :
