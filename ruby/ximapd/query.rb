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

class Ximapd
  class Query
    include DoubleDispatchable

    double_dispatch :accept, :visit

    def ==(other)
      return self.class == other.class
    end

    def &(other)
      return AndQuery.new([self, other])
    end

    def |(other)
      return OrQuery.new([self, other])
    end

    def -(other)
      return DiffQuery.new([self, other])
    end

    def self.parse(s)
      parser = QueryParser.new
      return parser.parse(s)
    end

    def null?
      return false
    end

    def composite?
      return false
    end

    private
    
    def quote(s)
      return format('"%s"', s.gsub(/[\\"]/, "\\\\\\&"))
    end
  end

  class NullQuery < Query
    def &(other)
      return other
    end

    def |(other)
      return other
    end

    def -(other)
      return other
    end

    def to_s
      return ""
    end

    def null?
      return true
    end
  end

  class CompositeQuery < Query
    attr_reader :operands

    def initialize(operands)
      @operands = operands
    end

    def ==(other)
      return super(other) && @operands == other.operands
    end

    def to_s
      return @operands.collect { |operand|
        if operand.composite?
          "( " + operand.to_s + " )"
        else
          operand.to_s
        end
      }.join(" " + operator + " ")
    end

    def composite?
      return true
    end

    private

    def operator
      raise SubclassResponsibilityError.new
    end
  end

  class AndQuery < CompositeQuery
    def &(other)
      return AndQuery.new(@operands + [other])
    end

    private

    def operator
      return "&"
    end
  end

  class OrQuery < CompositeQuery
    def |(other)
      return OrQuery.new(@operands + [other])
    end

    private

    def operator
      return "|"
    end
  end

  class DiffQuery < CompositeQuery
    def -(other)
      return DiffQuery.new(@operands + [other])
    end

    private

    def operator
      return "-"
    end
  end

  class TermQuery < Query
    attr_reader :value

    def initialize(value)
      @value = value
    end

    def ==(other)
      return super(other) && @value == other.value
    end

    def to_s
      return quote(@value)
    end
  end

  class PropertyQuery < Query
    attr_reader :name, :value

    def initialize(name, value)
      @name = name
      @value = value.to_s
    end

    def ==(other)
      return super(other) && @name == other.name && @value == other.value
    end

    def to_s
      return format("%s %s %s", @name, operator, quote(@value))
    end

    private

    def operator
      raise SubclassResponsibilityError.new
    end
  end

  class PropertyPeQuery < PropertyQuery
    private

    def operator
      return ":"
    end
  end

  class PropertyEqQuery < PropertyQuery
    private

    def operator
      return "="
    end
  end

  class PropertyLtQuery < PropertyQuery
    def swap
      return PropertyGtQuery.new(@value, @name)
    end

    private

    def operator
      return "<"
    end
  end

  class PropertyGtQuery < PropertyQuery
    def swap
      return PropertyLtQuery.new(@value, @name)
    end

    private

    def operator
      return ">"
    end
  end

  class PropertyLeQuery < PropertyQuery
    def swap
      return PropertyGeQuery.new(@value, @name)
    end

    private

    def operator
      return "<="
    end
  end

  class PropertyGeQuery < PropertyQuery
    def swap
      return PropertyLeQuery.new(@value, @name)
    end

    private

    def operator
      return ">="
    end
  end

  class AbstractFlagQuery < Query
    attr_reader :flag

    def initialize(flag)
      @flag = flag
    end

    def ==(other)
      return super(other) && @flag == other.flag
    end

    def to_s
      return format("%s : %s", key, quote(@flag))
    end

    def regexp
      if /\A\w/.match(@flag)
        return Regexp.new("\\b" + Regexp.quote(@flag) + "\\b", true, "n")
      else
        return Regexp.new(Regexp.quote(@flag) + "\\b", true, "n")
      end
    end

    private

    def key
      raise SubclassResponsibilityError.new
    end
  end

  class FlagQuery < AbstractFlagQuery
    private

    def key
      return "flag"
    end
  end

  class NoFlagQuery < AbstractFlagQuery
    private

    def key
      return "noflag"
    end
  end

  class QueryVisitor
    for method in Query.double_dispatched_methods[:visit]
      define_method(method) do |query, *args|
        visit_default(query, *args)
      end
    end

    private

    def visit_default(query, *args)
      raise SubclassResponsibilityError.new
    end
  end

  class QueryParser
    def initialize(logger = NullObject.new)
      @logger = logger
      @str = nil
      @pos = nil
      @token = nil
    end

    def parse(str)
      @str = str
      @pos = 0
      @token = nil
      return query
    end

    private

    T_AND    = :AND
    T_OR     = :OR
    T_NOT    = :NOT
    T_LPAR   = :LPAR
    T_RPAR   = :RPAR
    T_COLON  = :COLON
    T_EQ     = :EQ
    T_LT     = :LT
    T_GT     = :GT
    T_LE     = :LE
    T_GE     = :GE
    T_ATOM   = :ATOM
    T_QUOTED = :QUOTED
    T_EOF    = :EOF

    COMPOSITE_QUERY_OPERATORS = {
      T_AND => :&,
      T_OR => :|,
      T_NOT => :-,
    }

    def query
      result = NullQuery.new
      while (token = lookahead).symbol != T_EOF && token.symbol != T_RPAR
        result &= composite_query
      end
      return result
    end

    def composite_query
      result = primary_query
      while operator = COMPOSITE_QUERY_OPERATORS[lookahead.symbol]
        shift_token
        result = result.send(operator, primary_query)
      end
      return result
    end

    def primary_query
      token = lookahead
      case token.symbol
      when T_ATOM, T_QUOTED
        return term_or_property_query
      when T_LPAR
        return grouped_query
      else
        parse_error("unexpected token %s", token.symbol.id2name)
      end
    end

    def term_or_property_query
      term = string
      token = lookahead
      case token.symbol
      when T_COLON
        shift_token
        case term
        when "flag"
          return FlagQuery.new(string)
        when "noflag"
          return NoFlagQuery.new(string)
        else
          return PropertyPeQuery.new(term, string)
        end
      when T_EQ
        shift_token
        return PropertyEqQuery.new(term, string)
      when T_LT, T_GT, T_LE, T_GE
        return property_cmp_query(term)
      else
        return TermQuery.new(term)
      end
    end

    def property_cmp_query(name)
      token = shift_token
      value = string
      case token.symbol
      when T_LT
        result = PropertyLtQuery.new(name, value)
      when T_GT
        result = PropertyGtQuery.new(name, value)
      when T_LE
        result = PropertyLeQuery.new(name, value)
      when T_GE
        result = PropertyGeQuery.new(name, value)
      end
      token = lookahead
      if [T_LT, T_GT, T_LE, T_GE].include?(token.symbol)
        q1 = result.swap
        q2 = property_cmp_query(value)
        result = AndQuery.new([q1, q2])
      end
      return result
    end

    def grouped_query
      shift_token
      result = query
      match(T_RPAR)
      return result
    end

    def string
      return match(T_ATOM, T_QUOTED).value
    end

    def match(*args)
      token = lookahead
      unless args.include?(token.symbol)
        parse_error('unexpected token %s (expected %s)',
                    token.symbol.id2name,
                    args.collect {|i| i.id2name}.join(" or "))
      end
      shift_token
      return token
    end

    def lookahead
      unless @token
        @token = next_token
      end
      return @token
    end

    def shift_token
      token = @token
      @token = nil
      return token
    end

    TOKEN_REGEXP = /\G\s*(?:\
(?# 1:  AND    )(&)|\
(?# 2:  OR     )(\|)|\
(?# 3:  NOT    )(!|-)|\
(?# 4:  LPAR   )(\()|\
(?# 5:  RPAR   )(\))|\
(?# 6:  COLON  )(:)|\
(?# 7:  EQ     )(=)|\
(?# 8:  LE     )(<=)|\
(?# 9:  GE     )(>=)|\
(?# 10: LT     )(<)|\
(?# 11: GT     )(>)|\
(?# 12: QUOTED )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 13: ATOM   )([^\s:=<>&|!()]+)|\
(?# 14: EOF    )(\z))/ni

    ATOM_TOKENS = Hash.new(T_ATOM)
    ATOM_TOKENS["and"] = T_AND
    ATOM_TOKENS["or"] = T_OR
    ATOM_TOKENS["not"] = T_NOT
    ATOM_TOKENS["pe"] = T_COLON
    ATOM_TOKENS["eq"] = T_EQ
    ATOM_TOKENS["le"] = T_LE
    ATOM_TOKENS["ge"] = T_GE
    ATOM_TOKENS["lt"] = T_LT
    ATOM_TOKENS["gt"] = T_GT

    def next_token
      if @str.index(TOKEN_REGEXP, @pos)
        @pos = $~.end(0)
        if $1
          return Token.new(T_AND, $+)
        elsif $2
          return Token.new(T_OR, $+)
        elsif $3
          return Token.new(T_NOT, $+)
        elsif $4
          return Token.new(T_LPAR, $+)
        elsif $5
          return Token.new(T_RPAR, $+)
        elsif $6
          return Token.new(T_COLON, $+)
        elsif $6
          return Token.new(T_COLON, $+)
        elsif $7
          return Token.new(T_EQ, $+)
        elsif $8
          return Token.new(T_LE, $+)
        elsif $9
          return Token.new(T_GE, $+)
        elsif $10
          return Token.new(T_LT, $+)
        elsif $11
          return Token.new(T_GT, $+)
        elsif $12
          return Token.new(T_QUOTED, $+.gsub(/\\(["\\])/n, "\\1"))
        elsif $13
          s = $+
          return Token.new(ATOM_TOKENS[s.downcase], $+)
        elsif $14
          return Token.new(T_EOF, $+)
        else
          parse_error("[ximapd BUG] TOKEN_REGEXP is invalid")
        end
      else
        @str.index(/\S*/n, @pos)
        parse_error("unknown token - %s", $&.dump)
      end
    end

    def parse_error(fmt, *args)
      @logger.debug("@str: #{@str.inspect}")
      @logger.debug("@pos: #{@pos}")
      if @token && @token.symbol
        @logger.debug("@token.symbol: #{@token.symbol}")
        @logger.debug("@token.value: #{@token.value.inspect}")
      end
      raise QueryParseError, format(fmt, *args)
    end

    Token = Struct.new(:symbol, :value)
  end

  class QueryParseError < StandardError
  end
end
