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

class XimapdQueryTest < Test::Unit::TestCase
  include XimapdTestMixin

  def test_accept
    checker = MethodCallChecker.new

    q = Ximapd::Query.new
    assert_raise(Ximapd::SubclassResponsibilityError) do
      q.accept(checker)
    end

    q1 = Ximapd::NullQuery.new
    q1.accept(checker)
    assert_equal(:visit_null_query, checker.method_id)
    assert_equal([q1], checker.args)

    q2 = Ximapd::TermQuery.new("hello")
    q2.accept(checker)
    assert_equal(:visit_term_query, checker.method_id)
    assert_equal([q2], checker.args)

    q3 = Ximapd::PropertyEqQuery.new("subject", "hello")
    q3.accept(checker)
    assert_equal(:visit_property_eq_query, checker.method_id)
    assert_equal([q3], checker.args)

    q4 = Ximapd::AndQuery.new([q2, q3])
    q4.accept(checker)
    assert_equal(:visit_and_query, checker.method_id)
    assert_equal([q4], checker.args)
  end

  def test_eq
    assert_equal(Ximapd::NullQuery.new, Ximapd::NullQuery.new)
    assert_not_equal(Ximapd::TermQuery.new("hello"), Ximapd::NullQuery.new)
    assert_equal(Ximapd::TermQuery.new("hello"), Ximapd::TermQuery.new("hello"))
    assert_not_equal(Ximapd::NullQuery.new, Ximapd::TermQuery.new("hello"))
    assert_not_equal(Ximapd::TermQuery.new("hello"),
                     Ximapd::TermQuery.new("bye"))
    q1 = Ximapd::TermQuery.new("hello")
    q2 = Ximapd::PropertyEqQuery.new("subject", "hello")
    q3 = Ximapd::PropertyPeQuery.new("subject", "hello")
    assert_equal(Ximapd::AndQuery.new([q1, q2]),
                 Ximapd::AndQuery.new([q1, q2]))
    assert_not_equal(Ximapd::AndQuery.new([q1, q2]),
                     Ximapd::OrQuery.new([q1, q2]))
    assert_not_equal(Ximapd::AndQuery.new([q1, q2]),
                     Ximapd::AndQuery.new([q1, q3]))
  end

  def test_to_s
    q = Ximapd::NullQuery.new
    assert_equal('', q.to_s)

    q = Ximapd::TermQuery.new("hello")
    assert_equal('"hello"', q.to_s)

    q = Ximapd::TermQuery.new("\\\"")
    assert_equal('"\\\\\\""', q.to_s)

    q = Ximapd::PropertyPeQuery.new("subject", "hello")
    assert_equal('subject : "hello"', q.to_s)

    q = Ximapd::PropertyEqQuery.new("subject", "hello")
    assert_equal('subject = "hello"', q.to_s)

    q = Ximapd::PropertyLtQuery.new("date", "2005-08-24")
    assert_equal('date < "2005-08-24"', q.to_s)

    q = Ximapd::PropertyGtQuery.new("date", "2005-08-24")
    assert_equal('date > "2005-08-24"', q.to_s)

    q = Ximapd::PropertyLeQuery.new("date", "2005-08-24")
    assert_equal('date <= "2005-08-24"', q.to_s)

    q = Ximapd::PropertyGeQuery.new("date", "2005-08-24")
    assert_equal('date >= "2005-08-24"', q.to_s)

    q = Ximapd::AndQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal('"hello" & "bye"', q.to_s)

    q = Ximapd::OrQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal('"hello" | "bye"', q.to_s)

    q = Ximapd::NotQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal('"hello" - "bye"', q.to_s)

    q = Ximapd::Query.parse('hello | hi & bye')
    q = Ximapd::AndQuery.new([
      Ximapd::OrQuery.new([
        Ximapd::TermQuery.new("hello"),
        Ximapd::TermQuery.new("hi")
      ]),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal('( "hello" | "hi" ) & "bye"', q.to_s)
  end

  def test_parse
    q = Ximapd::Query.parse('hello')
    assert_equal(Ximapd::TermQuery.new("hello"), q)

    q = Ximapd::Query.parse('"hello"')
    assert_equal(Ximapd::TermQuery.new("hello"), q)

    q = Ximapd::Query.parse('subject : hello')
    assert_equal(Ximapd::PropertyPeQuery.new("subject", "hello"), q)

    q = Ximapd::Query.parse('subject = hello')
    assert_equal(Ximapd::PropertyEqQuery.new("subject", "hello"), q)

    q = Ximapd::Query.parse('date < 2005-08-24')
    assert_equal(Ximapd::PropertyLtQuery.new("date", "2005-08-24"), q)

    q = Ximapd::Query.parse('date > 2005-08-24')
    assert_equal(Ximapd::PropertyGtQuery.new("date", "2005-08-24"), q)

    q = Ximapd::Query.parse('date <= 2005-08-24')
    assert_equal(Ximapd::PropertyLeQuery.new("date", "2005-08-24"), q)

    q = Ximapd::Query.parse('date >= 2005-08-24')
    assert_equal(Ximapd::PropertyGeQuery.new("date", "2005-08-24"), q)

    q = Ximapd::Query.parse('2005-08-24 < date < 2005-08-25')
    expected = Ximapd::AndQuery.new([
      Ximapd::PropertyGtQuery.new("date", "2005-08-24"),
      Ximapd::PropertyLtQuery.new("date", "2005-08-25"),
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('2005-08-25 > date > 2005-08-24')
    expected = Ximapd::AndQuery.new([
      Ximapd::PropertyLtQuery.new("date", "2005-08-25"),
      Ximapd::PropertyGtQuery.new("date", "2005-08-24"),
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('2005-08-24 <= date <= 2005-08-25')
    expected = Ximapd::AndQuery.new([
      Ximapd::PropertyGeQuery.new("date", "2005-08-24"),
      Ximapd::PropertyLeQuery.new("date", "2005-08-25"),
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('2005-08-25 >= date >= 2005-08-24')
    expected = Ximapd::AndQuery.new([
      Ximapd::PropertyLeQuery.new("date", "2005-08-25"),
      Ximapd::PropertyGeQuery.new("date", "2005-08-24"),
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('hello & bye')
    expected = Ximapd::AndQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('hello | bye')
    expected = Ximapd::OrQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('hello - bye')
    expected = Ximapd::NotQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('hello-bye')
    assert_equal(Ximapd::TermQuery.new("hello-bye"), q)

    q = Ximapd::Query.parse('hello | hi & bye')
    expected = Ximapd::AndQuery.new([
      Ximapd::OrQuery.new([
        Ximapd::TermQuery.new("hello"),
        Ximapd::TermQuery.new("hi")
      ]),
      Ximapd::TermQuery.new("bye")
    ])
    assert_equal(expected, q)

    q = Ximapd::Query.parse('hello | (hi & bye)')
    expected = Ximapd::OrQuery.new([
      Ximapd::TermQuery.new("hello"),
      Ximapd::AndQuery.new([
        Ximapd::TermQuery.new("hi"),
        Ximapd::TermQuery.new("bye")
      ]),
    ])
    assert_equal(expected, q)
  end
end

# vim: set filetype=ruby expandtab sw=2 :
