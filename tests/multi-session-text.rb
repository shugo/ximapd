# $Id: session-test.rb 346 2006-09-01 05:58:17Z akira $
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

Ximapd::Session.test = true

class XimapdMultiSessionTest < Test::Unit::TestCase
  include XimapdTestMixin

  def setup
    super
    @challenge_generator =
      Ximapd::AuthenticateCramMD5Command.challenge_generator
    Ximapd::AuthenticateCramMD5Command.challenge_generator = Proc.new {
      "<12345@localhost>"
    }
    @mail_store = Ximapd::MailStore.new(@config)
    @ximapd = Ximapd.new
    class << @ximapd
      attr_accessor :mail_store
      attr_reader :sessions
    end
    @ximapd.mail_store = @mail_store
  end

  def teardown
    @mail_store.close
    @mail_store.teardown
    Ximapd::AuthenticateCramMD5Command.challenge_generator =
      @challenge_generator
    super
  end

  def test_copy
    mail_store = Ximapd::MailStore.new(@config)
    mail_store.uid_seq.current = 10
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
    mail_store.teardown

    sock1 = SpoofSocket.new('sock1')
    sock1.push_input(<<EOF)
A001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
EOF
    sess1 = Ximapd::Session.new(@config, sock1, @mail_store, @ximapd)
    th1 = Thread.start do
      @ximapd.sessions[Thread.current] = sess1
      sess1.start
      $stderr.puts "sess1 exit"
    end
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock1.pop_output)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock1.pop_output)
    assert_equal("A001 OK AUTHENTICATE completed\r\n", sock1.pop_output)

    sock2 = SpoofSocket.new('sock2')
    sock2.push_input(<<EOF)
B001 AUTHENTICATE CRAM-MD5\r
Zm9vIDk0YzgzZjJkZTAwODZlODMwNmUxNjc0NzA0MmI0OTc0\r
EOF
    sess2 = Ximapd::Session.new(@config, sock2, @mail_store, @ximapd)
    th2 = Thread.start do
      @ximapd.sessions[Thread.current] = sess2
      sess2.start
      $stderr.puts "sess2 exit"
    end
    assert_match(/\A\* OK ximapd version .*\r\n\z/, sock2.pop_output)
    assert_equal("+ PDEyMzQ1QGxvY2FsaG9zdD4=\r\n", sock2.pop_output)
    assert_equal("B001 OK AUTHENTICATE completed\r\n", sock2.pop_output)

    sock1.push_input "A002 SELECT INBOX\r\n"
    assert_equal("* 2 EXISTS\r\n", sock1.pop_output)
    assert_equal("* 2 RECENT\r\n", sock1.pop_output)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock1.pop_output)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock1.pop_output)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock1.pop_output)
    assert_equal("* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Seen \\Deleted \\*)] Limited\r\n",
                 sock1.pop_output)
    assert_equal("A002 OK [READ-WRITE] SELECT completed\r\n", sock1.pop_output)

    sock2.push_input "B002 SELECT Trash\r\n"
    assert_equal("* 0 EXISTS\r\n", sock2.pop_output)
    assert_equal("* 0 RECENT\r\n", sock2.pop_output)
    assert_equal("* OK [UIDVALIDITY 1] UIDs valid\r\n", sock2.pop_output)
    assert_equal("* OK [UIDNEXT #{uid2 + 1}] Predicted next UID\r\n",
                 sock2.pop_output)
    assert_equal("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n",
                 sock2.pop_output)
    assert_equal("* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Seen \\Deleted \\*)] Limited\r\n",
                 sock2.pop_output)
    assert_equal("B002 OK [READ-WRITE] SELECT completed\r\n", sock2.pop_output)

    sock1.push_input "A003 COPY 1:2 Trash\r\n"
    assert_equal("A003 OK COPY completed\r\n", sock1.pop_output)

    sock2.push_input "B003 NOOP\r\n"
    assert_equal("* 2 EXISTS\r\n", sock2.pop_output)
    assert_equal("B003 OK NOOP completed\r\n", sock2.pop_output)

  ensure
    th1.raise
    th2.raise
  end

  require 'thread'
  class SpoofSocket
    VERBOSE = false

    attr_reader :input, :output

    def initialize(s)
      @name = s
      @input = StringIO.new
      @output = StringIO.new
      @input_queue = Queue.new
      @output_queue = Queue.new
    end

    def push_input(str)
      @input_queue.push str
    end

    def pop_output
      @output_queue.pop
    end

    [:read, :gets, :getc].each do |mid|
      define_method(mid) do |*args|
        if @input.eof?
          @input.string = @input_queue.pop
        end
        r = @input.send(mid, *args)
        $stderr.puts "#{@name}: ->session: #{r.inspect}" if VERBOSE
        r
      end
    end

    def write(str)
      @output_queue.push(str.to_s)
      $stderr.puts "#{@name}: session->: #{str.inspect}" if VERBOSE
      str.size
    end
    def print(*args)
      tmp = args.collect{|x| x.to_s}.join('')
      @output_queue.push(tmp)
      $stderr.puts "#{@name}: session=>: #{tmp.inspect}" if VERBOSE
      nil
    end

    def peeraddr
      return ["AF_INET", 10143, "localhost", "127.0.0.1"]
    end

    def shutdown
    end

    def close
      @output.rewind
    end

    def fcntl(cmd, arg)
    end
  end
end

