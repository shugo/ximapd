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

    def merge(other, query_class)
      return query_class.new([self, other])
    end

    def self.parse(s)
      parser = QueryParser.new
      return parser.parse(s)
    end
  end

  class NullQuery < Query
    def merge(other, query_class)
      return other
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

    def merge(other, query_class)
      if self.is_a?(query_class)
        @operands.push(other)
        return self
      else
        return super(other, query_class)
      end
    end
  end

  class AndQuery < CompositeQuery
  end

  class OrQuery < CompositeQuery
  end

  class NotQuery < CompositeQuery
  end

  class TermQuery < Query
    attr_reader :value

    def initialize(value)
      @value = value
    end

    def ==(other)
      return super(other) && @value == other.value
    end
  end

  class PropertyQuery < Query
    attr_reader :name, :value

    def initialize(name, value)
      @name = name
      @value = value
    end

    def ==(other)
      return super(other) && @name == other.name && @value == other.value
    end
  end

  class PropertyPeQuery < PropertyQuery
  end

  class PropertyEqQuery < PropertyQuery
  end

  class PropertyLtQuery < PropertyQuery
    def swap
      return PropertyGtQuery.new(@value, @name)
    end
  end

  class PropertyGtQuery < PropertyQuery
    def swap
      return PropertyLtQuery.new(@value, @name)
    end
  end

  class PropertyLeQuery < PropertyQuery
    def swap
      return PropertyGeQuery.new(@value, @name)
    end
  end

  class PropertyGeQuery < PropertyQuery
    def swap
      return PropertyLeQuery.new(@value, @name)
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

    T_AND   = :AND
    T_OR    = :OR
    T_NOT   = :NOT
    T_LPAR  = :LPAR
    T_RPAR  = :RPAR
    T_COLON = :COLON
    T_EQ    = :EQ
    T_LT    = :LT
    T_GT    = :GT
    T_LE    = :LE
    T_GE    = :GE
    T_TERM  = :TERM
    T_EOF   = :EOF

    COMPOSITE_QUERY_CLASSES = {
      T_AND => AndQuery,
      T_OR => OrQuery,
      T_NOT => NotQuery,
    }

    def query
      result = NullQuery.new
      while (token = lookahead).symbol != T_EOF && token.symbol != T_RPAR
        result = result.merge(composite_query, AndQuery)
      end
      return result
    end

    def composite_query
      result = primary_query
      while query_class = COMPOSITE_QUERY_CLASSES[lookahead.symbol]
        shift_token
        result = result.merge(primary_query, query_class)
      end
      return result
    end

    def primary_query
      token = lookahead
      case token.symbol
      when T_TERM
        return term_or_property_query
      when T_LPAR
        return grouped_query
      else
        parse_error("unexpected token %s", token.symbol.id2name)
      end
    end

    def term_or_property_query
      token = shift_token
      term = token.value
      token = lookahead
      case token.symbol
      when T_COLON
        shift_token
        token = match(T_TERM)
        return PropertyPeQuery.new(term, token.value)
      when T_EQ
        shift_token
        token = match(T_TERM)
        return PropertyEqQuery.new(term, token.value)
      when T_LT, T_GT, T_LE, T_GE
        return property_cmp_query(term)
      else
        return TermQuery.new(term)
      end
    end

    def property_cmp_query(name)
      token = shift_token
      value = match(T_TERM).value
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
(?# 1:  AND   )(&)|\
(?# 2:  OR    )(\|)|\
(?# 3:  NOT   )(!|-)|\
(?# 4:  LPAR  )(\()|\
(?# 5:  RPAR  )(\))|\
(?# 6:  COLON )(:)|\
(?# 7:  EQ    )(=)|\
(?# 8:  LE    )(<=)|\
(?# 9:  GE    )(>=)|\
(?# 10: LT    )(<)|\
(?# 11: GT    )(>)|\
(?# 12: TERM  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 13: TERM  )([^\s:=<>&|!()]+)|\
(?# 14: EOF   )(\z))/ni

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
          return Token.new(T_TERM,
                           $+.gsub(/\\(["\\])/n, "\\1"))
        elsif $13
          return Token.new(T_TERM, $+)
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
