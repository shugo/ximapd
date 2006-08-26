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

require "estraier"
include Estraier

module Estraier
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
        "#{@db.err_msg(errno)} (#{errno})"
      else
        '(unknown error)'
      end
    end
  end
end

class Ximapd
  class HyperEstraierBackend < Backend
    def setup
      @close_count = 0
      @close_index_interval = 1
      if @config["close_index_interval"]
	tmp = @config["close_index_interval"].to_i
	@close_index_interval = tmp if tmp > 0
      end
      unless File.exist?(@index_path)
        db = Estraier::DatabaseWrapper.new()
        begin
          db.open(@index_path,
                  Estraier::Database::DBWRITER|Estraier::Database::DBCREAT|Estraier::Database::DBPERFNG)
        ensure
          begin
            db.close
          rescue
          end
        end
      end
    end

    def teardown
      if @index
        @index.close
        @index = nil
	@close_count = 0
      end
      super
    end

    def standby
      # noop
    end

    def relax
      # noop
    end

    def register(mail_data, filename)
      doc = Estraier::Document.new
      doc.add_attr("@uri", "file://" + File.expand_path(filename))
      doc.add_text(mail_data.text)
      mail_data.properties.each_pair do |name, value|
        doc.add_attr(name, value.to_s)
      end
      set_flags_internal(doc, mail_data.flags)
      @index.put_doc(doc)
    end

    def get_flags(uid, item_id, item_obj)
      if item_obj
	doc = item_obj
      else
	open do
	  doc = get_doc(uid, item_id, item_obj)
	end
      end
      begin
        doc.attr("flags").scan(/[^<>\s]+/).join(" ")
      rescue ArgumentError
        ""
      end
    end

    def set_flags(uid, item_id, item_obj, flags)
      open do
        doc = get_doc(uid, item_id, item_obj)
        set_flags_internal(doc, flags)
        @index.edit_doc(doc)
      end
    end

    def delete_flags(uid, item_id, item_obj)
      set_flags(uid, item_id, item_obj, "")
    end

    def delete(uid, item_id)
      @index.out_doc(item_id)
    end

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

    def uid_fetch(mailbox, sequence_set)
      if sequence_set.empty?
        return []
      end
      mailbox_query = mailbox.query
      result = query(mailbox_query)
      seq_number = Hash.new
      result.each_index do |i|
	 seq_number[result[i]] = i+1
      end

      mails = []
      result = []
      querys = NullQuery.new
      sequence_set.collect do |i|
        case i
        when Range
          if i.last == -1
	    querys |= PropertyGeQuery.new("uid", i.first)
          else
	    querys |= PropertyGeQuery.new("uid", i.first) & 
	              PropertyLeQuery.new("uid", i.last)
          end
        else
          querys |= PropertyEqQuery.new("uid", i)
        end
      end
      querys = mailbox_query & querys 
      result = query(querys)
      result.each do |item_id|
        doc = get_doc(nil, item_id, nil)
        uid = doc.attr("uid").to_i
        mails << IndexedMail.new(@config, mailbox, seq_number[item_id], uid,
                                   item_id, doc.attr("internal-date"),
                                   doc)
      end

      mails
    end

    def mailbox_status(mailbox)
      mailbox_status = MailboxStatus.new

      mailbox_query = mailbox.query
      result = query(mailbox_query)
      mailbox_status.messages = result.length
      result = query(mailbox_query &
                     NoFlagQuery.new("\\Seen"))
      mailbox_status.unseen = result.length
      result = query(mailbox_query &
                     PropertyGtQuery.new("uid", mailbox["last_peeked_uid"]))
      mailbox_status.recent = result.length
      mailbox_status
    end

    def query(query, index = @index)
      visitor = QueryExecutingVisitor.new(index)
      return visitor.visit(query)
    end

    def uid_search(query)
      result = query(query)
      result.collect { |item_id| get_uid(item_id) }
    end

    def rebuild_index(*args)
      if args.empty?
        flags = Estraier::Database::DBWRITER|Estraier::Database::DBCREAT|Estraier::Database::DBPERFNG
      else
        flags = args.last
      end
      old_index_path = @index_path + ".old"

      @old_index = nil
      begin
	if @close_index_interval > 1
	  @index.close
	  @index = nil
	  @close_count = 0
	end
        File.rename(@index_path, old_index_path)
        @old_index = Estraier::DatabaseWrapper.new()
        begin
          @old_index.open(old_index_path, Estraier::Database::DBREADER)
        rescue
          begin
            @old_index.close
          rescue
          end
          raise
        end
      rescue Errno::ENOENT
      end
      @index = Estraier::DatabaseWrapper.new()
      @index.open(@index_path, flags)
      begin
        yield
        FileUtils.rm_rf(old_index_path)
      ensure
        @old_index = nil
      end
    end

    def get_old_flags(uid)
      raise RuntimeError, "old index not given" unless @old_index

      doc = get_doc_internal(@old_index, uid, nil, nil)
      begin
        doc.attr("flags")
      rescue ArgumentError
        ""
      end
    end

    def try_query(query)
      query(Query.parse(query))
    end

    private

    def open_index(*args)
      return if @index
      if args.empty?
        flags = Estraier::Database::DBWRITER
      else
        flags = args.last
      end
      @index = Estraier::DatabaseWrapper.new()
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
      @close_count += 1
      return if @close_count < @close_index_interval
      @index.close
      @index = nil
      @close_count = 0
    end

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
        doc_id = query(PropertyEqQuery.new("uid", uid), index)[0]
        doc = index.get_doc(doc_id, 0)
      else
        doc = nil
      end
      unless doc
        raise ArgumentError,
          "no such document (uid = #{uid.inspect}, item_id = #{item_id.inspect})"
      end
      doc
    end

    def set_flags_internal(doc, flags)
      doc.add_attr("flags", "<" + flags.strip.split(/\s+/).join("><") + ">")
    end

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
          return visit_default(query)
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
          return visit_default(query)
        rescue QueryCompileError
          result = []
          for q in query.operands
            result |= q.accept(self)
          end
          return result
        end
      end

      def visit_diff_query(query)
        begin
          return visit_default(query)
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
        result = @index.search(cond)
	res = []
	for i in 0...result.doc_num
	  res.push(result.get_doc_id(i))
	end
        return res
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
        @cond = Estraier::Condition.new
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
        @cond.add_attr("flags #{prefix}ISTRINC <#{query.flag}>")
        return ""
      end

      def visit_no_flag_query(query)
        prefix = @invert ? "" : "!"
        @cond.add_attr("flags #{prefix}ISTRINC <#{query.flag}>")
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
  end
end
