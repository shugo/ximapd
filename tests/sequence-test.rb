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

class XimapdSequenceTest < Test::Unit::TestCase
  include XimapdTestMixin

  def test_current
    path = File.expand_path("uid.seq", @tmpdir)
    seq = Ximapd::Sequence.new(path)
    assert_equal(nil, seq.current)
    seq.next
    assert_equal(1, seq.current)
    assert_equal(1, seq.current)
    seq.next
    assert_equal(2, seq.current)
    assert_equal(2, seq.current)

    seq2 = Ximapd::Sequence.new(path)
    assert_equal(2, seq2.current)
  end

  def test_current=
    path = File.expand_path("uid.seq", @tmpdir)
    seq = Ximapd::Sequence.new(path)
    assert_equal(nil, seq.current)
    seq.current = 5
    assert_equal(5, seq.current)
    seq.current = 10
    seq2 = Ximapd::Sequence.new(path)
    assert_equal(10, seq2.current)
  end

  def test_next
    path = File.expand_path("uid.seq", @tmpdir)
    seq = Ximapd::Sequence.new(path)
    assert_equal(1, seq.next)
    assert_equal(2, seq.next)

    seq2 = Ximapd::Sequence.new(path)
    assert_equal(3, seq2.next)
  end

  def test_peek_next
    path = File.expand_path("uid.seq", @tmpdir)
    seq = Ximapd::Sequence.new(path)
    assert_equal(1, seq.peek_next)
    seq.next
    assert_equal(2, seq.peek_next)
    assert_equal(2, seq.peek_next)

    seq2 = Ximapd::Sequence.new(path)
    assert_equal(2, seq2.peek_next)
  end
end
