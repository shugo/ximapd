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
  class CommandParser
    def initialize(session, logger)
      @session = session
      @logger = logger
      @str = nil
      @pos = nil
      @lex_state = nil
      @token = nil
    end

    def parse(str)
      @str = str
      @pos = 0
      @lex_state = EXPR_BEG
      @token = nil
      return command
    end

    private

    EXPR_BEG          = :EXPR_BEG
    EXPR_DATA         = :EXPR_DATA
    EXPR_TEXT         = :EXPR_TEXT
    EXPR_RTEXT        = :EXPR_RTEXT
    EXPR_CTEXT        = :EXPR_CTEXT

    T_SPACE   = :SPACE
    T_NIL     = :NIL
    T_NUMBER  = :NUMBER
    T_ATOM    = :ATOM
    T_QUOTED  = :QUOTED
    T_LPAR    = :LPAR
    T_RPAR    = :RPAR
    T_BSLASH  = :BSLASH
    T_STAR    = :STAR
    T_LBRA    = :LBRA
    T_RBRA    = :RBRA
    T_LITERAL = :LITERAL
    T_PLUS    = :PLUS
    T_PERCENT = :PERCENT
    T_CRLF    = :CRLF
    T_EOF     = :EOF
    T_TEXT    = :TEXT

    BEG_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 3:  NUMBER  )(\d+)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 4:  ATOM    )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+]+)|\
(?# 5:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\))|\
(?# 8:  BSLASH  )(\\)|\
(?# 9:  STAR    )(\*)|\
(?# 10: LBRA    )(\[)|\
(?# 11: RBRA    )(\])|\
(?# 12: LITERAL )\{(\d+)\}\r\n|\
(?# 13: PLUS    )(\+)|\
(?# 14: PERCENT )(%)|\
(?# 15: CRLF    )(\r\n)|\
(?# 16: EOF     )(\z))/ni

    DATA_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)|\
(?# 3:  NUMBER  )(\d+)|\
(?# 4:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 5:  LITERAL )\{(\d+)\}\r\n|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\)))/ni

    TEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n]*))/ni

    RTEXT_REGEXP = /\G(?:\
(?# 1:  LBRA    )(\[)|\
(?# 2:  TEXT    )([^\x00\r\n]*))/ni

    CTEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n\]]*))/ni

    Token = Struct.new(:symbol, :value)

    UNIVERSAL_COMMANDS = [
      "CAPABILITY",
      "STARTTLS",
      "NOOP",
      "LOGOUT"
    ]
    NON_AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "AUTHENTICATE",
      "LOGIN"
    ]
    AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "SELECT",
      "EXAMINE",
      "CREATE",
      "DELETE",
      "RENAME",
      "SUBSCRIBE",
      "UNSUBSCRIBE",
      "LIST",
      "LSUB",
      "STATUS",
      "APPEND",
      "IDLE"
    ]
    SELECTED_STATE_COMMANDS = AUTHENTICATED_STATE_COMMANDS + [
      "CHECK",
      "CLOSE",
      "EXPUNGE",
      "SEARCH",
      "UID SEARCH",
      "FETCH",
      "UID FETCH",
      "STORE",
      "UID STORE",
      "UID COPY"
    ]
    LOGOUT_STATE_COMMANDS = []
    COMMANDS = {
      NON_AUTHENTICATED_STATE => NON_AUTHENTICATED_STATE_COMMANDS,
      AUTHENTICATED_STATE => AUTHENTICATED_STATE_COMMANDS,
      SELECTED_STATE => SELECTED_STATE_COMMANDS,
      LOGOUT_STATE => LOGOUT_STATE_COMMANDS
    }

    def command
      result = NullCommand.new
      token = lookahead
      if token.symbol == T_CRLF || token.symbol == T_EOF
        result = NullCommand.new
      else
        tag = atom
        token = lookahead
        if token.symbol == T_CRLF || token.symbol == T_EOF
          result = MissingCommand.new
        else
          match(T_SPACE)
          name = atom.upcase
          if name == "UID"
            match(T_SPACE)
            name += " " + atom.upcase
          end
          if COMMANDS[@session.state].include?(name)
            if @session.config["require_secure"] &&
                !@session.secure? &&
                !UNIVERSAL_COMMANDS.include?(name)
              result = RequireSecureSessionCommand.new
            else
              result = send(name.tr(" ", "_").downcase)
              result.name = name
              match(T_CRLF)
              match(T_EOF)
            end
          else
            result = UnrecognizedCommand.new
          end
        end
        result.tag = tag
      end
      result.session = @session
      return result
    end

    def capability
      return CapabilityCommand.new
    end

    def starttls
      return StarttlsCommand.new
    end

    def noop
      return NoopCommand.new
    end

    def logout
      return LogoutCommand.new
    end

    def authenticate
      match(T_SPACE)
      auth_type = atom.upcase
      case auth_type
      when "CRAM-MD5"
        return AuthenticateCramMD5Command.new
      else
        raise format("unknown auth type: %s", auth_type)
      end
    end

    def login
      match(T_SPACE)
      userid = astring
      match(T_SPACE)
      password = astring
      return LoginCommand.new(userid, password)
    end

    def select
      match(T_SPACE)
      mailbox_name = mailbox
      return SelectCommand.new(mailbox_name)
    end

    def examine
      match(T_SPACE)
      mailbox_name = mailbox
      return ExamineCommand.new(mailbox_name)
    end

    def create
      match(T_SPACE)
      mailbox_name = mailbox
      return CreateCommand.new(mailbox_name)
    end

    def delete
      match(T_SPACE)
      mailbox_name = mailbox
      return DeleteCommand.new(mailbox_name)
    end

    def rename
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      new_mailbox_name = mailbox
      return RenameCommand.new(mailbox_name, new_mailbox_name)
    end

    def subscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def unsubscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def list
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def lsub
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def list_mailbox
      token = lookahead
      if string_token?(token)
        s = string
        if /\AINBOX\z/ni.match(s)
          return "INBOX"
        else
          return s
        end
      else
        result = ""
        loop do
          token = lookahead
          if list_mailbox_token?(token)
            result.concat(token.value)
            shift_token
          else
            if result.empty?
              parse_error("unexpected token %s", token.symbol)
            else
              if /\AINBOX\z/ni.match(result)
                return "INBOX"
              else
                return result
              end
            end
          end
        end
      end
    end

    LIST_MAILBOX_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS,
      T_STAR,
      T_PERCENT
    ]

    def list_mailbox_token?(token)
      return LIST_MAILBOX_TOKENS.include?(token.symbol)
    end

    def status
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      match(T_LPAR)
      atts = []
      atts.push(status_att)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        atts.push(status_att)
      end
      return StatusCommand.new(mailbox_name, atts)
    end

    def status_att
      att = atom.upcase
      unless /\A(MESSAGES|RECENT|UIDNEXT|UIDVALIDITY|UNSEEN)\z/.match(att)
        parse_error("unknown att `%s'", att)
      end
      return att
    end

    def mailbox
      result = astring
      if /\AINBOX\z/ni.match(result)
        return "INBOX"
      else
        return result
      end
    end

    def append
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
        match(T_SPACE)
        token = lookahead
      else
        flags = []
      end
      if token.symbol == T_QUOTED
        shift_token
        datetime = token.value
        match(T_SPACE)
      else
        datetime = nil
      end
      token = match(T_LITERAL)
      message = token.value
      return AppendCommand.new(mailbox_name, flags, datetime, message)
    end

    def idle
      return IdleCommand.new
    end

    def check
      return NoopCommand.new
    end

    def close
      return CloseCommand.new
    end

    def expunge
      return ExpungeCommand.new
    end

    def search
      return parse_search(SearchCommand)
    end

    def uid_search
      return parse_search(UidSearchCommand)
    end

    def parse_search(command_class)
      match(T_SPACE)
      token = lookahead
      if token.value == "CHARSET"
        shift_token
        match(T_SPACE)
        charset = astring
        match(T_SPACE)
      else
        charset = "us-ascii"
      end
      return command_class.new(search_keys(charset))
    end

    def search_keys(charset)
      result = [search_key(charset)]
      loop do
        token = lookahead
        if token.symbol != T_SPACE
          break
        end
        shift_token
        result.push(search_key(charset))
      end
      return result
    end

    def search_key(charset)
      ic = @session.mail_store.backend_class
      token = lookahead
      if /\A(\d+|\*)/.match(token.value)
        return ic::SequenceNumberSearchKey.new(sequence_set)
      elsif token.symbol == T_LPAR
        shift_token
        keys = []
        until (key = search_key(charset)).kind_of?(ic::EndGroupSearchKey)
          keys << key
        end
        return ic::GroupSearchKey.new(keys)
      elsif token.symbol == T_RPAR
        shift_token
        return ic::EndGroupSearchKey.new
      end

      name = tokens([T_ATOM, T_NUMBER, T_NIL, T_PLUS, T_STAR])
      case name.upcase
      when "UID"
        match(T_SPACE)
        return ic::UidSearchKey.new(sequence_set)
      when "BODY", "TEXT"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::BodySearchKey.new(s)
      when "HEADER"
        match(T_SPACE)
        header_name = astring.downcase
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new(header_name, s)
      when "SUBJECT"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new("subject", s)
      when "FROM"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new("from", s)
      when "TO"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new("to", s)
      when "CC"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new("cc", s)
      when "BCC"
        match(T_SPACE)
        s = Iconv.conv("utf-8", charset, astring)
        return ic::HeaderSearchKey.new("bcc", s)
      when "BEFORE"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::BeforeSearchKey.new(s)
      when "ON"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::OnSearchKey.new(s)
      when "SINCE"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::SinceSearchKey.new(s)
      when "SENTBEFORE"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::SentbeforeSearchKey.new(s)
      when "SENTON"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::SentonSearchKey.new(s)
      when "SENTSINCE"
        match(T_SPACE)
        s = tokens([T_ATOM, T_QUOTED])
        return ic::SentsinceSearchKey.new(s)
      when "LARGER"
        match(T_SPACE)
        s = tokens([T_NUMBER])
        return ic::LargerSearchKey.new(s)
      when "SMALLER"
        match(T_SPACE)
        s = tokens([T_NUMBER])
        return ic::SmallerSearchKey.new(s)
      when "ANSWERED"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Answered")
      when "DELETED"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Deleted")
      when "DRAFT"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Draft")
      when "FLAGGED"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Flagged")
      when "RECENT", "NEW"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Recent")
      when "SEEN"
        return ic::FlagSearchKey.new(@session.mail_store, "\\Seen")
      when "KEYWORD"
        match(T_SPACE)
        flag = atom
        return ic::KeywordSearchKey.new(@session.mail_store, flag)
      when "UNANSWERED"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Answered")
      when "UNDELETED"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Deleted")
      when "UNDRAFT"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Draft")
      when "UNFLAGGED"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Flagged")
      when "UNSEEN"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Seen")
      when "OLD"
        return ic::NoFlagSearchKey.new(@session.mail_store, "\\Recent")
      when "UNKEYWORD"
        match(T_SPACE)
        flag = atom
        return ic::NoKeywordSearchKey.new(@session.mail_store, flag)
      when "NOT"
        match(T_SPACE)
        return ic::NotSearchKey.new(search_key(charset))
      when "OR"
        match(T_SPACE)
        key1 = search_key(charset)
        match(T_SPACE)
        key2 = search_key(charset)
        return ic::OrSearchKey.new(key1, key2)
      else
        return ic::NullSearchKey.new
      end
    end

    def fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return FetchCommand.new(seq_set, atts)
    end

    def uid_fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return UidFetchCommand.new(seq_set, atts)
    end

    def fetch_atts
      token = lookahead
      if token.symbol == T_LPAR
        shift_token
        result = []
        result.push(fetch_att)
        loop do
          token = lookahead
          if token.symbol == T_RPAR
            shift_token
            break
          end
          match(T_SPACE)
          result.push(fetch_att)
        end
        return result
      else
        case token.value
        when "ALL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          return result
        when "FAST"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          return result
        when "FULL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          result.push(BodyFetchAtt.new)
          return result
        else
          return [fetch_att]
        end
      end
    end

    def fetch_att
      token = match(T_ATOM)
      case token.value
      when /\A(?:ENVELOPE)\z/ni
        return EnvelopeFetchAtt.new
      when /\A(?:FLAGS)\z/ni
        return FlagsFetchAtt.new
      when /\A(?:RFC822)\z/ni
        return RFC822FetchAtt.new
      when /\A(?:RFC822\.HEADER)\z/ni
        return RFC822HeaderFetchAtt.new
      when /\A(?:RFC822\.SIZE)\z/ni
        return RFC822SizeFetchAtt.new
      when /\A(?:BODY)?\z/ni
        token = lookahead
        if token.symbol != T_LBRA
          return BodyFetchAtt.new
        end
        return BodySectionFetchAtt.new(section, opt_partial, false)
      when /\A(?:BODY\.PEEK)\z/ni
        return BodySectionFetchAtt.new(section, opt_partial, true)
      when /\A(?:BODYSTRUCTURE)\z/ni
        return BodyStructureFetchAtt.new
      when /\A(?:UID)\z/ni
        return UidFetchAtt.new
      when /\A(?:INTERNALDATE)\z/ni
        return InternalDateFetchAtt.new
      else
        parse_error("unknown attribute `%s'", token.value)
      end
    end

    def section
      match(T_LBRA)
      token = lookahead
      if token.symbol != T_RBRA
        s = tokens([T_ATOM, T_NUMBER, T_NIL, T_PLUS])
        case s
        when /\A(?:(?:([0-9.]+)\.)?(HEADER|TEXT))\z/ni
          result = Section.new($1, $2.upcase)
        when /\A(?:(?:([0-9.]+)\.)?(HEADER\.FIELDS(?:\.NOT)?))\z/ni
          match(T_SPACE)
          result = Section.new($1, $2.upcase, header_list)
        when /\A(?:([0-9.]+)\.(MIME))\z/ni
          result = Section.new($1, $2.upcase)
        when /\A([0-9.]+)\z/ni
          result = Section.new($1)
        else
          parse_error("unknown section `%s'", s)
        end
      end
      match(T_RBRA)
      return result
    end

    def header_list
      result = []
      match(T_LPAR)
      result.push(astring.upcase)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        result.push(astring.upcase)
      end
      return result
    end

    def opt_partial
      token = lookahead
      if m = /<(\d+)\.(\d+)>/.match(token.value)
        shift_token
        return Partial.new(m[1].to_i, m[2].to_i)
      end
      return nil
    end
    Partial = Struct.new(:offset, :size)

    def store
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      att = store_att_flags
      return StoreCommand.new(seq_set, att)
    end

    def uid_store
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      att = store_att_flags
      return UidStoreCommand.new(seq_set, att)
    end

    def store_att_flags
      item = atom
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
      else
        flags = []
        flags.push(flag)
        loop do
          token = lookahead
          if token.symbol != T_SPACE
            break
          end
          shift_token
          flags.push(flag)
        end
      end
      case item
      when /\AFLAGS(\.SILENT)?\z/ni
        return SetFlagsStoreAtt.new(flags, !$1.nil?)
      when /\A\+FLAGS(\.SILENT)?\z/ni
        return AddFlagsStoreAtt.new(flags, !$1.nil?)
      when /\A-FLAGS(\.SILENT)?\z/ni
        return RemoveFlagsStoreAtt.new(flags, !$1.nil?)
      else
        parse_error("unkown data item - `%s'", item)
      end
    end

    FLAG_REGEXP = /\
(?# FLAG        )(\\[^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)/n

    def flag_list
      match(T_LPAR)
      if @str.index(/([^)]*)\)/ni, @pos)
        @pos = $~.end(0)
        return $1.scan(FLAG_REGEXP).collect { |flag, atom|
          atom || flag
        }
      else
        parse_error("invalid flag list")
      end
    end

    EXACT_FLAG_REGEXP = /\A\
(?# FLAG        )\\([^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)\z/n

    def flag
      result = atom
      unless EXACT_FLAG_REGEXP.match(s)
        parse_error("invalid flag")
      end
      return result
    end

    def sequence_set
      s = ""
      loop do
        token = lookahead
        break if !atom_token?(token) && token.symbol != T_STAR
        shift_token
        s.concat(token.value)
      end
      return s.split(/,/n).collect { |i|
        x, y = i.split(/:/n)
        if y.nil?
          parse_seq_number(x)
        else
          parse_seq_number(x) .. parse_seq_number(y)
        end
      }
    end

    def parse_seq_number(s)
      if s == "*"
        return -1
      else
        return s.to_i
      end
    end

    def uid_copy
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      mailbox_name = mailbox
      return UidCopyCommand.new(seq_set, mailbox_name)
    end

    def astring
      token = lookahead
      if string_token?(token)
        return string
      else
        return atom
      end
    end

    def string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value
    end

    STRING_TOKENS = [T_QUOTED, T_LITERAL, T_NIL]

    def string_token?(token)
      return STRING_TOKENS.include?(token.symbol)
    end

    def case_insensitive_string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value.upcase
    end

    def tokens(tokens)
      result = ""
      loop do
        token = lookahead
        if tokens.include?(token.symbol)
          result.concat(token.value)
          shift_token
        else
          if result.empty?
            parse_error("unexpected token %s", token.symbol)
          else
            return result
          end
        end
      end
    end

    ATOM_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS
    ]

    def atom
      return tokens(ATOM_TOKENS)
    end

    def atom_token?(token)
      return ATOM_TOKENS.include?(token.symbol)
    end

    def number
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_NUMBER)
      return token.value.to_i
    end

    def nil_atom
      match(T_NIL)
      return nil
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
      @token = nil
    end

    def next_token
      case @lex_state
      when EXPR_BEG
        if @str.index(BEG_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_ATOM, $+)
          elsif $5
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          elsif $8
            return Token.new(T_BSLASH, $+)
          elsif $9
            return Token.new(T_STAR, $+)
          elsif $10
            return Token.new(T_LBRA, $+)
          elsif $11
            return Token.new(T_RBRA, $+)
          elsif $12
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $13
            return Token.new(T_PLUS, $+)
          elsif $14
            return Token.new(T_PERCENT, $+)
          elsif $15
            return Token.new(T_CRLF, $+)
          elsif $16
            return Token.new(T_EOF, $+)
          else
            parse_error("[ximapd BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_DATA
        if @str.index(DATA_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $5
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          else
            parse_error("[ximapd BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_TEXT
        if @str.index(TEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] TEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_RTEXT
        if @str.index(RTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_LBRA, $+)
          elsif $2
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] RTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_CTEXT
        if @str.index(CTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] CTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos) #/
          parse_error("unknown token - %s", $&.dump)
        end
      else
        parse_error("illegal @lex_state - %s", @lex_state.inspect)
      end
    end

    def parse_error(fmt, *args)
      @logger.debug("@str: #{@str.inspect}")
      @logger.debug("@pos: #{@pos}")
      @logger.debug("@lex_state: #{@lex_state}")
      if @token && @token.symbol
        @logger.debug("@token.symbol: #{@token.symbol}")
        @logger.debug("@token.value: #{@token.value.inspect}")
      end
      raise CommandParseError, format(fmt, *args)
    end
  end

  class CommandParseError < StandardError
  end

  class Command
    attr_reader :session
    attr_accessor :tag, :name

    def initialize
      @session = nil
      @config = nil
      @tag = nil
      @name = nil
    end

    def session=(session)
      @session = session
      @config = session.config
      @mail_store = session.mail_store
      @logger = @config["logger"]
    end

    def send_tagged_ok(code = nil)
      if code.nil?
        @session.send_tagged_ok(@tag, "%s completed", @name)
      else
        @session.send_tagged_ok(@tag, "[%s] %s completed", code, @name)
      end
    end
  end

  class NullCommand < Command
    def exec
      @session.send_bad("Null command")
    end
  end

  class MissingCommand < Command
    def exec
      @session.send_tagged_bad(@tag, "Missing command")
    end
  end

  class UnrecognizedCommand < Command
    def exec
      msg = "Command unrecognized"
      if @session.state == NON_AUTHENTICATED_STATE
        msg.concat("/login please")
      end
      @session.send_tagged_bad(@tag, msg)
    end
  end

  class RequireSecureSessionCommand < Command
    def exec
      @session.send_tagged_no(@tag, "secure session required by the server/use IMAPS or TLS please")
    end
  end

  class CapabilityCommand < Command
    def exec
      capa = "CAPABILITY IMAP4REV1 IDLE LOGINDISABLED AUTH=CRAM-MD5"
      if @session.config["starttls"]
        capa += " STARTTLS"
      end
      @session.send_data(capa)
      send_tagged_ok
    end
  end

  class StarttlsCommand < Command
    def exec
      begin
        @session.starttls
        send_tagged_ok
      rescue => e
        @session.send_tagged_bad(@tag, e.message)
      end
      begin
        @session.starttls_accept
      rescue Exception => e
        @session.send_tagged_bad(@tag, e.message)
      end
    end
  end

  class NoopCommand < Command
    def exec
      @session.synchronize do
        @session.sync
      end
      send_tagged_ok
    end
  end

  class LogoutCommand < Command
    def exec
      @session.synchronize do
        @session.sync
      end
      @session.send_data("BYE IMAP server terminating connection")
      send_tagged_ok
      @session.logout
    end
  end

  class AuthenticateCramMD5Command < Command
    def exec
      challenge = @@challenge_generator.call
      @session.send_continue_req([challenge].pack("m").gsub("\n", ""))
      line = @session.recv_line
      s = line.unpack("m")[0]
      digest = hmac_md5(challenge, @config["password"])
      expected = @config["user"] + " " + digest
      if s == expected
        @session.login
        send_tagged_ok
      else
        sleep(3)
        @session.send_tagged_no(@tag, "AUTHENTICATE failed")
      end
    end

    @@challenge_generator = Proc.new {
      format("<%s.%f@%s>",
             Process.pid, Time.new.to_f,
             TCPSocket.gethostbyname(Socket.gethostname)[0])
    }

    def self.challenge_generator
      return @@challenge_generator
    end

    def self.challenge_generator=(proc)
      @@challenge_generator = proc
    end

    private

    def hmac_md5(text, key)
      if key.length > 64
        key = Digest::MD5.digest(key)
      end

      k_ipad = key + "\0" * (64 - key.length)
      k_opad = key + "\0" * (64 - key.length)
      for i in 0..63
        k_ipad[i] ^= 0x36
        k_opad[i] ^= 0x5c
      end

      digest = Digest::MD5.digest(k_ipad + text)

      return Digest::MD5.hexdigest(k_opad + digest)
    end
  end

  class LoginCommand < Command
    def initialize(userid, password)
      @userid = userid
      @password = password
    end

    def exec
      @session.send_tagged_no(@tag, "LOGIN failed")
    end
  end

  class MailboxCheckCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      begin
        status = nil
        @session.synchronize do
          status = @mail_store.get_mailbox_status(@mailbox_name,
                                                  @session.read_only?)
        end
        @session.send_data("%d EXISTS", status.messages)
        @session.send_data("%d RECENT", status.recent)
        @session.send_ok("[UIDVALIDITY %d] UIDs valid", status.uidvalidity)
        @session.send_ok("[UIDNEXT %d] Predicted next UID", status.uidnext)
        @session.send_data("FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
        @session.send_ok("[PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Seen \\Deleted \\*)] Limited")
        send_tagged_response
      rescue MailboxError => e
        @session.send_tagged_no(@tag, "%s", e)
      end
    end

    private

    def send_tagged_response
      raise ScriptError.new("subclass must override send_tagged_response")
    end
  end

  class SelectCommand < MailboxCheckCommand
    private

    def send_tagged_response
      @session.synchronize do
        #@session.sync
        @session.select(@mailbox_name)
      end
      send_tagged_ok("READ-WRITE")
    end
  end

  class ExamineCommand < MailboxCheckCommand
    private

    def send_tagged_response
      @session.synchronize do
        #@session.sync
        @session.examine(@mailbox_name)
      end
      send_tagged_ok("READ-ONLY")
    end
  end

  class CreateCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      begin
        @session.synchronize do
          @mail_store.create_mailbox(@mailbox_name)
        end
        send_tagged_ok
      rescue InvalidQueryError
        @session.send_tagged_no(@tag, "invalid query")
      end
    end
  end

  class DeleteCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      if /\A(INBOX|ml|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't delete %s", @mailbox_name)
        return
      end
      @session.synchronize do
        @mail_store.delete_mailbox(@mailbox_name)
      end
      send_tagged_ok
    end
  end

  class RenameCommand < Command
    def initialize(mailbox_name, new_mailbox_name)
      @mailbox_name = mailbox_name
      @new_mailbox_name = new_mailbox_name
    end

    def exec
      if /\A(INBOX|ml|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't rename %s", @mailbox_name)
        return
      end
      begin
        @session.synchronize do
          @mail_store.rename_mailbox(@mailbox_name, @new_mailbox_name)
        end
        send_tagged_ok
      rescue InvalidQueryError
        @session.send_tagged_no(@tag, "invalid query")
      rescue MailboxExistError
        @session.send_tagged_no(@tag, "mailbox already exists")
      rescue NoMailboxError
        @session.send_tagged_no(@tag, "mailbox does not exist")
      end
    end
  end

  class ListCommand < Command
    include DataFormat

    def initialize(reference_name, mailbox_name)
      @reference_name = reference_name
      @mailbox_name = mailbox_name
    end

    def exec
      unless @reference_name.empty?
        @session.send_tagged_no(@tag, "%s failed", @name)
        return
      end
      if @mailbox_name.empty?
        @session.send_data("%s (\\Noselect) \"/\" \"\"", @name)
        send_tagged_ok
        return
      end
      pat = @mailbox_name.gsub(/\*|%|[^*%]+/n) { |s|
        case s
        when "*"
          ".*"
        when "%"
          "[^/]*"
        else
          Regexp.quote(s)
        end
      }
      re = Regexp.new("\\A" + pat + "\\z", nil, "n")
      mailboxes = nil
      @session.synchronize do
        mailboxes = @mail_store.mailboxes.to_a.select { |mbox_name,|
          re.match(mbox_name)
        }
      end
      mailboxes.sort_by { |i| i[0] }.each do |mbox_name, mbox|
        @session.send_data("%s (%s) \"/\" %s",
                           @name, mbox["flags"], quoted(mbox_name))
      end
      send_tagged_ok
    end
  end

  class StatusCommand < Command
    include DataFormat

    def initialize(mailbox_name, atts)
      @mailbox_name = mailbox_name
      @atts = atts
    end

    def exec
      status = nil
      @session.synchronize do
        status = @mail_store.get_mailbox_status(@mailbox_name,
                                                @session.read_only?)
      end
      s = @atts.collect { |att|
        format("%s %d", att, status.send(att.downcase))
      }.join(" ")
      @session.send_data("STATUS %s (%s)", quoted(@mailbox_name), s)
      send_tagged_ok
    end
  end

  class AppendCommand < Command
    def initialize(mailbox_name, flags, datetime, message)
      @mailbox_name = mailbox_name
      @flags = flags
      @datetime = datetime
      @message = message
    end

    def exec
      @session.synchronize do
        @mail_store.import_mail(@message, @mailbox_name, @flags.join(" "))
      end
      send_tagged_ok
    end
  end

  class IdleCommand < Command
    def exec
      @session.send_continue_req("Waiting for DONE")
      @session.synchronize do
        @session.sync
        @mail_store.mailbox_db.transaction do
          for plugin in @mail_store.plugins
            plugin.on_idle
          end
        end
      end
      @session.recv_line
      send_tagged_ok
    end
  end

  class CloseCommand < Command
    def exec
      @session.synchronize do
        @session.sync
        mailbox = @session.get_current_mailbox
        mails = mailbox.fetch([1 .. -1])
        deleted_mails = mails.select { |mail|
          /\\Deleted\b/ni.match(mail.flags(false))
        }
        @mail_store.delete_mails(deleted_mails)
      end
      @session.close_mailbox
      send_tagged_ok
    end
  end

  class ExpungeCommand < Command
    def exec
      deleted_seqnos = nil
      @session.synchronize do
        @session.sync
        mailbox = @session.get_current_mailbox
        mails = mailbox.fetch([1 .. -1])
        deleted_mails = mails.select { |mail|
          /\\Deleted\b/ni.match(mail.flags(false))
        }.reverse
        deleted_seqnos = deleted_mails.collect { |mail|
          mail.seqno
        }
        @mail_store.delete_mails(deleted_mails)
      end
      for seqno in deleted_seqnos
        @session.send_data("%d EXPUNGE", seqno)
      end
      send_tagged_ok
    end
  end

  class AbstractSearchCommand < Command
    def initialize(keys)
      @keys = keys
    end

    def exec
      result = nil
      @session.synchronize do
        mailbox = @session.get_current_mailbox
        uids = mailbox.uid_search_by_keys(@keys)
        result = create_result(mailbox, uids)
      end
      if result.empty?
        @session.send_data("SEARCH")
      else
        @session.send_data("SEARCH %s", result.join(" "))
      end
      send_tagged_ok
    end

    private

    def create_result(uids)
      raise ScriptError.new("subclass must override this method")
    end
  end

  class SearchCommand < AbstractSearchCommand
    private

    def create_result(mailbox, uids)
      if uids.empty?
        return []
      else
        mails = mailbox.fetch([1 .. -1])
        uid_tbl = uids.inject({}) { |tbl, uid|
          tbl[uid] = true
          tbl
        }
        return mails.inject([]) { |ary, mail|
          if uid_tbl.key?(mail.uid)
            ary.push(mail.seqno)
          end
          ary
        }
      end
    end
  end

  class UidSearchCommand < AbstractSearchCommand
    private

    def create_result(mailbox, uids)
      return uids
    end
  end

  class AbstractFetchCommand < Command
    def initialize(sequence_set, atts)
      @sequence_set = sequence_set
      @atts = atts
    end

    def exec
      mails = nil
      @session.synchronize do
        mailbox = @session.get_current_mailbox
        mails = fetch(mailbox)
      end
      for mail in mails
        data = nil
        @session.synchronize do
          data = @atts.collect { |att|
            att.fetch(mail)
          }.join(" ")
        end
        send_fetch_response(mail, data)
      end
      send_tagged_ok
    end

    private

    def fetch(mailbox)
      raise ScriptError.new("subclass must override this method")
    end

    def send_fetch_response(mail, flags)
      raise ScriptError.new("subclass must override this method")
    end
  end

  class FetchCommand < AbstractFetchCommand
    private

    def fetch(mailbox)
      return mailbox.fetch(@sequence_set)
    end

    def send_fetch_response(mail, data)
      @session.send_data("%d FETCH (%s)", mail.seqno, data)
    end
  end

  class UidFetchCommand < FetchCommand
    def initialize(sequence_set, atts)
      super(sequence_set, atts)
      unless @atts[0].kind_of?(UidFetchAtt)
        @atts.unshift(UidFetchAtt.new)
      end
    end

    private

    def fetch(mailbox)
      return mailbox.uid_fetch(@sequence_set)
    end

    def send_fetch_response(mail, data)
      @session.send_data("%d FETCH (%s)", mail.uid, data)
    end
  end

  class EnvelopeFetchAtt
    def fetch(mail)
      return format("ENVELOPE %s", mail.envelope)
    end
  end

  class FlagsFetchAtt
    def fetch(mail)
      return format("FLAGS (%s)", mail.flags)
    end
  end

  class InternalDateFetchAtt
    include DataFormat

    def fetch(mail)
      indate = mail.internal_date.strftime("%d-%b-%Y %H:%M:%S %z")
      return format("INTERNALDATE %s", quoted(indate))
    end
  end

  class RFC822FetchAtt
    include DataFormat

    def fetch(mail)
      return format("RFC822 %s", literal(mail.to_s))
    end
  end

  class RFC822HeaderFetchAtt
    include DataFormat

    def fetch(mail)
      return format("RFC822.HEADER %s", literal(mail.header))
    end
  end

  class RFC822SizeFetchAtt
    def fetch(mail)
      return format("RFC822.SIZE %s", mail.size)
    end
  end

  class RFC822TextFetchAtt
    def fetch(mail)
    end
  end

  class BodyFetchAtt
    def fetch(mail)
      return format("BODY %s", mail.body_structure(false))
    end
  end

  class BodyStructureFetchAtt
    def fetch(mail)
      return format("BODYSTRUCTURE %s", mail.body_structure(true))
    end
  end

  class UidFetchAtt
    def fetch(mail)
      return format("UID %s", mail.uid)
    end
  end

  class BodySectionFetchAtt
    include DataFormat

    def initialize(section, partial, peek)
      @section = section
      @partial = partial
      @peek = peek
    end

    def fetch(mail)
      if @section.nil? || @section.text.nil?
        if @section.nil?
          part = nil
        else
          part = @section.part
        end
        result = format_data(mail.mime_body(part))
        unless @peek
          flags = mail.flags(false)
          unless /\\Seen\b/ni.match(flags)
            if flags.empty?
              flags = "\\Seen"
            else
              flags += " \\Seen"
            end
            mail.flags = flags
            result += format(" FLAGS (%s)", flags)
          end
        end
        return result
      end
      case @section.text
      when "MIME"
        s = mail.mime_header(@section.part)
        return format_data(s)
      when "HEADER"
        s = mail.header(@section.part)
        return format_data(s)
      when "HEADER.FIELDS"
        s = mail.header_fields(@section.header_list, @section.part)
        return format_data(s)
      end
    end

    private
    
    def format_data(data)
      if @section.nil?
        section = ""
      else
        if @section.text.nil?
          section = @section.part
        else
          if @section.part.nil?
            section = @section.text
          else
            section = @section.part + "." + @section.text
          end
          if @section.text == "HEADER.FIELDS"
            section += " (" + @section.header_list.collect { |i|
              quoted(i)
            }.join(" ") + ")"
          end
        end
      end
      if @partial
        s = data[@partial.offset, @partial.size]
        return format("BODY[%s]<%d> %s", section, @partial.offset, literal(s))
      else
        return format("BODY[%s] %s", section, literal(data))
      end
    end
  end

  Section = Struct.new(:part, :text, :header_list)

  class AbstractStoreCommand < Command
    def initialize(sequence_set, att)
      @sequence_set = sequence_set
      @att = att
    end

    def exec
      mails = nil
      @session.synchronize do
        mailbox = @session.get_current_mailbox
        mails = fetch(mailbox)
      end
      unless @session.read_only?
        for mail in mails
          flags = nil
          @session.synchronize do
            @att.store(mail)
            flags = mail.flags
          end
          unless @att.silent?
            send_fetch_response(mail, flags)
          end
        end
      end
      send_tagged_ok
    end

    private

    def fetch(mailbox)
      raise ScriptError.new("subclass must override this method")
    end

    def send_fetch_response(mail, flags)
      raise ScriptError.new("subclass must override this method")
    end
  end

  class StoreCommand < AbstractStoreCommand
    private

    def fetch(mailbox)
      return mailbox.fetch(@sequence_set)
    end

    def send_fetch_response(mail, flags)
      @session.send_data("%d FETCH (FLAGS (%s))", mail.seqno, flags)
    end
  end

  class UidStoreCommand < AbstractStoreCommand
    private

    def fetch(mailbox)
      return mailbox.uid_fetch(@sequence_set)
    end

    def send_fetch_response(mail, flags)
      @session.send_data("%d FETCH (FLAGS (%s) UID %d)",
                         mail.uid, flags, mail.uid)
    end
  end

  class FlagsStoreAtt
    def initialize(flags, silent = false)
      @flags = flags
      @silent = silent
    end

    def silent?
      return @silent
    end
  end

  class SetFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      mail.flags = @flags.join(" ")
    end
  end

  class AddFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      flags = mail.flags(false).split(/ /)
      flags |= @flags
      mail.flags = flags.join(" ")
    end
  end

  class RemoveFlagsStoreAtt < FlagsStoreAtt
    def store(mail)
      flags = mail.flags(false).split(/ /)
      flags -= @flags
      mail.flags = flags.join(" ")
    end
  end

  class UidCopyCommand < Command
    def initialize(sequence_set, mailbox_name)
      @sequence_set = sequence_set
      @mailbox_name = mailbox_name
    end

    def exec
      mails = nil
      dest_mailbox = nil
      @session.synchronize do
        mailbox = @session.get_current_mailbox
        mails = mailbox.uid_fetch(@sequence_set)
        @mail_store.mailbox_db.transaction(true) do
          dest_mailbox = @mail_store.get_mailbox(@mailbox_name)
        end
      end
      override = {"x-ml-name" => dest_mailbox["list_id"] || ""}
      for mail in mails
        @session.synchronize do
          for plugin in @mail_store.plugins
            plugin.on_copy(mail, dest_mailbox)
          end
          uid = @mail_store.import_mail(mail.to_s, dest_mailbox.name,
                                        mail.flags(false), mail.internal_date,
                                        override)
          dest_mail = dest_mailbox.get_mail(uid)
          for plugin in @mail_store.plugins
            plugin.on_copied(mail, dest_mail)
          end
        end
      end
      send_tagged_ok
    end
  end
end
