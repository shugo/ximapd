# $Id$
# Copyright (C) 2005  akira yamada <akira@arika.org>
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

require "HyperEstraier"

module HyperEstraier
  class DatabaseWrapper
    class Error < RuntimeError; end

    def initialize()
      @db = Database.new()
    end

    def open(*args)
      unless @db.open(*args)
        raise Error, "could not open index: #{error_message}"
      end
      yield(self) if block_given?
      nil
    end

    def close
      @db.close
    end

    def put_doc(doc, opt = 0)
      unless @db.put_doc(doc, opt)
        raise Error, "could not put documennt: #{error_message}"
      end
      doc.id
    end

    def out_doc(doc_id, opt = 0)
      unless @db.out_doc(doc_id, opt)
        raise Error, "could not out documennt: #{error_message}"
      end
    end

    def edit_doc(doc)
      unless @db.edit_doc(doc)
        raise Error, "could not edit documment: #{error_message}"
      end
    end

    def get_doc(doc_id, opt = 0)
      begin
        @db.get_doc(doc_id, opt)
      rescue
        nil
      end
    end

    def search(*args)
      @db.search(*args)
    end

    def error
      error = nil
      begin
        error = @db.error
      rescue IOError
      end

      error
    end

    def error_message
      errno = error
      if errno
        "#{HyperEstraier::Database.err_msg(errno)} (#{errno})"
      else
        '(unknown error)'
      end
    end
  end
end

class Ximapd
  class HyperEstraierBackend < Backend
    private

    def setup
      unless File.exist?(@index_path)
        db = HyperEstraier::DatabaseWrapper.new()
        begin
          db.open(@index_path,
                  HyperEstraier::Database::DBWRITER|HyperEstraier::Database::DBCREAT|HyperEstraier::Database::DBPERFNG)
        ensure
          begin
            db.close
          rescue
          end
        end
      end
    end
    public :setup

    def standby
      # noop
    end
    public :standby

    def relax
      # noop
    end
    public :relax

    def open_index(*args)
      if args.empty?
        flags = HyperEstraier::Database::DBWRITER
      else
        flags = args.last
      end
      @index = HyperEstraier::DatabaseWrapper.new()
      begin
        @index.open(@index_path, flags)
      rescue
        begin
          @index.close
        rescue
        end
        raise
      end
    end

    def close_index
      @index.close
      @index = nil
    end

    def register(mail_data, filename)
      doc = HyperEstraier::Document.new
      doc.add_attr("@uri", "file://" + File.expand_path(filename))
      doc.add_text(mail_data.text)
      mail_data.properties.each_pair do |name, value|
        doc.add_attr(name, value.to_s)
      end
      set_flags_internal(doc, mail_data.flags)
      @index.put_doc(doc)
    end
    public :register

    def get_uid(item_id)
      uid = nil
      if doc = @index.get_doc(item_id, 0)
        begin
          uid = doc.attr("uid").to_i
        rescue ArgumentError
          raise "item_id:#{item_id} doesnot have uid"
        end
      end
      uid
    end

    def get_doc(uid, item_id, item_obj)
      get_doc_internal(@index, uid, item_id, item_obj)
    end

    def get_doc_internal(index, uid, item_id, item_obj)
      if item_obj
        doc = item_obj
      elsif item_id
        doc = index.get_doc(item_id, 0)
      elsif uid
        doc_id = query(PropertyEqQuery.new("uid", uid))[0]
        doc = index.get_doc(doc_id, 0)
      else
        doc = nil
      end
      unless doc
        raise ArgumentError,
          "no such document (uid = #{uid.inspect}, item_id = #{item_id.inspect}, indexed_data.class = #{indexed_data.class})"
      end
      doc
    end

    def get_flags(uid, item_id, item_obj)
      open do
        doc = get_doc(uid, item_id, item_obj)
        begin
          doc.attr("flags").scan(/[^<>\s]+/).join(" ")
        rescue ArgumentError
          ""
        end
      end
    end
    public :get_flags

    def set_flags(uid, item_id, item_obj, flags)
      open do
        doc = get_doc(uid, item_id, item_obj)
        set_flags_internal(doc, flags)
        @index.edit_doc(doc)
      end
    end
    public :set_flags

    def set_flags_internal(doc, flags)
      doc.add_attr("flags", "<" + flags.strip.split(/\s+/).join("><") + ">")
    end

    def delete_flags(uid, item_id, item_obj)
      set_flags(uid, item_id, item_obj, "")
    end
    public :delete_flags

    def delete(uid, item_id)
      @index.out_doc(item_id)
    end
    public :delete

    def fetch(mailbox, sequence_set)
      result = query(mailbox.query)
      mails = []
      sequence_set.each do |seq_number|
        case seq_number
        when Range
          first = seq_number.first
          last = seq_number.last == -1 ? result.length : seq_number.last
          for i in first .. last
            item_id = result[i - 1]
            doc = get_doc(nil, item_id, nil)
            mail = IndexedMail.new(@config, mailbox, i,
                                   doc.attr("uid").to_i, doc.id,
                                   doc.attr("internal-date"), doc)
            mails.push(mail)
          end
        else
          begin
            doc_id = result.to_a[seq_number - 1]
          rescue IndexError
            next
          end
          doc = get_doc(nil, doc_id, nil)
          mail = IndexedMail.new(@config, mailbox, seq_number,
                                 doc.attr("uid").to_i, doc.id,
                                 doc.attr("internal-date"), doc)
          mails.push(mail)
        end
      end
      mails
    end
    public :fetch

    def uid_fetch(mailbox, sequence_set)
      if sequence_set.empty?
        return []
      end
      mailbox_query = mailbox.query

      mails = []
      result = []
      sequence_set.collect do |i|
        sq = []
        case i
        when Range
          if i.last == -1
            q = mailbox_query & PropertyGeQuery.new("uid", i.first)
          else
            q = mailbox_query &
              PropertyGeQuery.new("uid", i.first) &
              PropertyLeQuery.new("uid", i.last)
          end
        else
          q = mailbox_query & PropertyEqQuery.new("uid", i)
        end
        result += query(q)
      end
      result.each do |item_id|
        doc = get_doc(nil, item_id, nil)
        uid = doc.attr("uid").to_i
        mails << IndexedMail.new(@config, mailbox, uid, uid,
                                 item_id, doc.attr("internal-date"),
                                 doc)
      end

      mails
    end
    public :uid_fetch

    def mailbox_status(mailbox)
      mailbox_status = MailboxStatus.new

      mailbox_query = mailbox.query
      result = query(mailbox_query)
      mailbox_status.messages = result.length
      mailbox_status.unseen = result.select { |item_id|
        !/\\Seen\b/ni.match(get_flags(nil, item_id, nil))
      }.length
      result = query(mailbox_query &
                     PropertyGtQuery.new("uid", mailbox["last_peeked_uid"]))
      mailbox_status.recent = result.length
      mailbox_status
    end
    public :mailbox_status

    def query(query)
      visitor = QueryExecutingVisitor.new(@index)
      return visitor.visit(query)
    end
    public :query

    def uid_search(query)
      result = query(query)
      result.collect { |item_id| get_uid(item_id) }
    end
    public :uid_search

    def rebuild_index(*args)
      if args.empty?
        flags = HyperEstraier::Database::DBWRITER|HyperEstraier::Database::DBCREAT|HyperEstraier::Database::DBPERFNG
      else
        flags = args.last
      end
      old_index_path = @index_path + ".old"

      @old_index = nil
      begin
        File.rename(@index_path, old_index_path)
        @old_index = HyperEstraier::DatabaseWrapper.new()
        begin
          @old_index.open(old_index_path, HyperEstraier::Database::DBREADER)
        rescue
          begin
            @old_index.close
          rescue
          end
          raise
        end
      rescue Errno::ENOENT
      end
      @index = HyperEstraier::DatabaseWrapper.new()
      @index.open(@index_path, flags)
      @index.close
      begin
        yield
        FileUtils.rm_rf(old_index_path)
      ensure
        @old_index = nil
      end
    end
    public :rebuild_index

    def get_old_flags(uid)
      raise RuntimeError, "old index not given" unless @old_index

      doc = get_doc_internal(@old_index, uid, nil, nil)
      begin
        doc.attr("flags")
      rescue ArgumentError
        ""
      end
    end
    public :get_old_flags

    def try_query(query)
      query(Query.parse(query))
    end
    public :try_query

    class QueryExecutingVisitor < QueryVisitor
      def initialize(index)
        @index = index
        @query_compiling_visitor = QueryCompilingVisitor.new
      end

      def visit(query)
        return query.accept(self)
      end

      def visit_and_query(query)
        begin
          cond = @query_compiling_visitor.visit(query)
          cond.set_order("uid NUMA")
          result = @index.search(cond, 0)
          return result.to_a
        rescue QueryCompileError
          first, *rest = query.operands
          result = first.accept(self)
          for q in rest
            result &= q.accept(self)
          end
          return result
        end
      end

      def visit_or_query(query)
        begin
          cond = @query_compiling_visitor.visit(query)
          cond.set_order("uid NUMA")
          result = @index.search(cond, 0)
          return result.to_a
        rescue QueryCompileError
          result = []
          for operand in query.operands
            result |= operand.accept(self)
          end
          return result
        end
      end

      def visit_diff_query(query)
        begin
          cond = @query_compiling_visitor.visit(query)
          cond.set_order("uid NUMA")
          result = @index.search(cond, 0)
          return result.to_a
        rescue QueryCompileError
          first, *rest = query.operands
          result = first.accept(self)
          for q in rest
            result -= q.accept(self)
          end
          return result
        end
      end

      private

      def visit_default(query)
        cond = @query_compiling_visitor.visit(query)
        cond.set_order("uid NUMA")
        result = @index.search(cond, 0)
        return result.to_a
      end

      def search(query)
        cond = @query_compiling_visitor.visit(query)
        cond.set_order("uid NUMA")
        result = @index.search(cond, 0)
        return result.to_a
      end

      def compile_property_query(query, operator)
        @cond.add_attr("#{query.name} #{operator} #{query.value}")
        return ""
      end

      def compile_composite_query(query, operator)
        return query.operands.collect { |operand|
          operand.accept(self)
        }.reject { |s| s.empty? }.join(" " + operator + " ")
      end

      def numeric_or_date_property?(property)
        return NUMERIC_OR_DATE_PROPERTIES.include?(property)
      end
    end

    class QueryCompilingVisitor < QueryVisitor
      NUMERIC_OR_DATE_PROPERTIES = [
        "uid",
        "size",
        "internal-date",
        "flags",
        "mailbox-id",
        "date",
        "x-mail-count"
      ]

      def initialize
        @cond = nil
        @invert = false
      end

      def visit(query)
        @cond = HyperEstraier::Condition.new
        phrase = query.accept(self)
        unless phrase.empty?
          @cond.set_phrase(phrase)
        end
        return @cond
      end

      def visit_term_query(query)
        return query.value
      end

      def visit_property_pe_query(query)
        return compile_property_query(query, "STRINC")
      end

      def visit_property_eq_query(query)
        if numeric_or_date_property?(query.name)
          return compile_property_query(query, "NUMEQ")
        else
          return compile_property_query(query, "STREQ")
        end
      end

      def visit_property_lt_query(query)
        unless numeric_or_date_property?(query.name)
          raise InvalidQueryError.new("#{query.name} is not a numeric property")
        end
        return compile_property_query(query, "NUMLT")
      end

      def visit_property_gt_query(query)
        unless numeric_or_date_property?(query.name)
          raise InvalidQueryError.new("#{query.name} is not a numeric property")
        end
        return compile_property_query(query, "NUMGT")
      end

      def visit_property_le_query(query)
        unless numeric_or_date_property?(query.name)
          raise InvalidQueryError.new("#{query.name} is not a numeric property")
        end
        return compile_property_query(query, "NUMLE")
      end

      def visit_property_ge_query(query)
        unless numeric_or_date_property?(query.name)
          raise InvalidQueryError.new("#{query.name} is not a numeric property")
        end
        return compile_property_query(query, "NUMGE")
      end

      def visit_flag_query(query)
        prefix = @invert ? "!" : ""
        @cond.add_attr("flags #{prefix}STRINC <#{query.flag}>")
        return ""
      end

      def visit_no_flag_query(query)
        prefix = @invert ? "" : "!"
        @cond.add_attr("flags #{prefix}STRINC <#{query.flag}>")
        return ""
      end

      def visit_and_query(query)
        if query.operands.any? { |operand|
          operand.composite? && !operand.is_a?(AndQuery)
        }
          raise QueryCompileError.new("operands must be non-composite or AND")
        end
        return apply_operator("AND", query.operands)
      end

      def visit_or_query(query)
        if query.operands.any? { |operand| !operand.is_a?(TermQuery) }
          raise QueryCompileError.new("operands must be TERM")
        end
        return apply_operator("OR", query.operands)
      end

      def visit_diff_query(query)
        first, *rest = query.operands
        if rest.any? { |operand| operand.composite? }
          raise QueryCompileError.new("operands must be non-composite")
        end
        s = first.accept(self)
        if s.empty?
          raise QueryCompileError.new("first operand must not be empty")
        end
        @invert = true
        begin
          s2 = apply_operator("ANDNOT", rest)
        ensure
          @invert = false
        end
        if s2.empty?
          return s
        else
          return s + " ANDNOT " + s2
        end
      end

      private

      def compile_property_query(query, operator)
        prefix = @invert ? "!" : ""
        @cond.add_attr("#{query.name} #{prefix}#{operator} #{query.value}")
        return ""
      end

      def apply_operator(operator, operands)
        return operands.collect { |operand|
          operand.accept(self)
        }.reject { |s| s.empty? }.join(" " + operator + " ")
      end

      def numeric_or_date_property?(property)
        return NUMERIC_OR_DATE_PROPERTIES.include?(property)
      end
    end

    class QueryCompileError < StandardError; end

    class AbstractSearchKey
      def to_query
        nil
      end

      def exec
        raise
      end
    end

    class NullSearchKey < AbstractSearchKey
      def to_query
        {"main" => "", "sub" => []}
      end
    end

    class BodySearchKey < AbstractSearchKey
      def initialize(value)
        @value = value
      end

      def to_query
        {"main" => @value, "sub" => []}
      end
    end

    class HeaderSearchKey < AbstractSearchKey
      def initialize(name, value)
        @name = name
        @value = value
      end

      def to_query
        query = nil
        case @name
        when "subject"
          return {"main" => "", 
                  "sub" => [format("@title STRINC %s", @value)]}
        when "from", "to", "cc", "bcc"
          return {"main" => "",
                   "sub" => [format("%s STRINC %s", @name, @value)]}
        when "x-ml-name", "x-mail-count"
          return {"main" => "",
                   "sub" => [format("%s STREQ %s", @name, @value)]}
        else
          return {"main" => "", "sub" => []}
        end
      end
    end

    class FlagSearchKey < AbstractSearchKey
      def initialize(mail_store, flag)
        @mail_store = mail_store
        @flag = "<" + flag + ">"
      end

      def to_query
        return {"main" => "", "sub" => [format("flags STRINC %s", @flag)]}
      end
    end

    class NoFlagSearchKey < FlagSearchKey
      def to_query
        return {"main" => "", "sub" => [format("flags !STRINC %s", @flag)]}
      end
    end

    class KeywordSearchKey < FlagSearchKey
      def to_query
        return {"main" => "", "sub" => [format("flags STRINC %s", @flag)]}
      end
    end

    class NoKeywordSearchKey < FlagSearchKey
      def to_query
        return {"main" => "", "sub" => [format("flags !STRINC %s", @flag)]}
      end
    end

    class SequenceNumberSearchKey < AbstractSearchKey
      def initialize(sequence_set)
        @sequence_set = sequence_set
      end

      def to_query
        raise NotImplementedError.new("sequence number search is not implemented")
      end
      def exec(index, mailbox, result)
        raise NotImplementedError.new("sequence number search is not implemented")
      end
    end

    class UidSearchKey < AbstractSearchKey
      def initialize(sequence_set)
        @sequence_set = sequence_set
      end

      def exec(index, mailbox, result)
        if @sequence_set.empty?
          return result
        end
        sr = []
        @sequence_set.collect { |i|
          sq = []
          case i
          when Range
            if i.last == -1
              sq << format("uid NUMGE %d", i.first)
            else
              sq << format("uid NUMGE %d", i.first)
              sq << format("uid NUMLE %d", i.last)
            end
          else
            sq << format("uid NUMEQ %d", i)
          end
          sr |= index.query(mailbox, {"main" => "", "sub" => sq})
        }
        return result & sr
      end
    end

    class NotSearchKey < AbstractSearchKey
      def initialize(key)
        @key = key
      end

      def exec(index, mailbox, result)
        result - index.query_by_keys(mailbox, [@key])
      end
    end

    class DateSearchKey < NullSearchKey
      def to_query
        return {"main" => format("%s %s %s", field, op, @date.strftime()),
                "sub" => nil}
      end

      private

      def initialize(date_str)
        @date = parse_date(date_str)
        @date.gmtime
      end

      MONTH = {
        "Jan" =>  1, "Feb" =>  2, "Mar" =>  3, "Apr" =>  4,
        "May" =>  5, "Jun" =>  6, "Jul" =>  7, "Aug" =>  8,
        "Sep" =>  9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
      }
      def parse_date(date_str)
        if date_str.match(/\A"?(\d{1,2})-(#{MONTH.keys.join("|")})-(\d{4})"?\z/o)
          Time.local($3.to_i, MONTH[$2], $1.to_i)
        else
          raise "invlid date string #{date_str}"
        end
      end

      def date_str(date)
        date.strftime("%Y-%m-%dT%H:%M:%S")
      end
    end

    class BeforeSearchKey < DateSearchKey
      def to_query
        return {"main" => "",
                "sub" => [format("@cdate NUMLT %s", date_str(@date))]}
      end
    end

    class OnSearchKey < DateSearchKey
      def to_query
        date_end = @date + 86400
        return {"main" => "",
                "sub" => [format("@cdate NUMGE %s", date_str(@date)),
                          format("@cdate NUMLT %s", date_str(date_end))]}
      end
    end

    class SinceSearchKey < DateSearchKey
      def to_query
        date = @date + 86400
        return {"main" => "",
                "sub" => [format("@cdate NUMGE %s", date_str(date))]}
      end
    end

    class SentbeforeSearchKey < DateSearchKey
      def to_query
        return {"main" => "",
                "sub" => [format("date NUMLT %s", date_str(@date))]}
      end
    end

    class SentonSearchKey < DateSearchKey
      def to_query
        date_end = @date + 86400
        return {"main" => "",
                "sub" => [format("date NUMGE %s", date_str(@date)),
                          format("date NUMLT %s", date_str(date_end))]}
      end
    end

    class SentsinceSearchKey < DateSearchKey
      def to_query
        date = @date + 86400
        return {"main" => "",
                "sub" => [format("date NUMGE %s", date_str(date))]}
      end
    end

    class LargerSearchKey < NullSearchKey
      def initialize(size_str)
        @size_str = size_str
      end

      def to_query
        return {"main" => "", "sub" => [format("@size NUMGT %s", @size_str)]}
      end
    end

    class SmallerSearchKey < LargerSearchKey
      def to_query
        return {"main" => "", "sub" => [format("@size NUMLT %s", @size_str)]}
      end
    end

    class OrSearchKey < AbstractSearchKey
      def initialize(key1, key2)
        @keys = [key1, key2]
      end

      def exec(index, mailbox, result)
        sresult = []
        @keys.each do |key|
          sresult |= index.query_by_keys(mailbox, [key])
        end

        result & sresult
      end
    end

    class GroupSearchKey < AbstractSearchKey
      def initialize(keys)
        @keys = keys
      end

      def exec(index, mailbox, result)
        result & index.query_by_keys(mailbox, @keys)
      end
    end

    class EndGroupSearchKey
    end
  end
end
