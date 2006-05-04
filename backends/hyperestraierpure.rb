# $Id: hyperestraier.rb 333 2006-01-12 16:02:21Z shugo $
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

require "estraierpure"
require "net/http"
require "uri"

module EstraierPure
  class Document
    def id
      @attrs["@id"]
    end
  end
end

class Ximapd
  class HyperEstraierPureBackend < Backend
    def initialize(*args)
      super(*args)
      @index = nil
    end

    def setup
      unless File.exist?(@index_path)
        system("estmaster init #{@index_path} >/dev/null")
      end
      system("estmaster start -bg #{@index_path} >/dev/null")
      sleep(1) # XXX: wait a bit.

      # XXX:
      host = "localhost"
      port = 1978
      user = "admin"
      pass = "admin"
      nodeurl = "http://#{host}:#{port}/node/ximapd"

      Net::HTTP.post_form(URI("http://#{URI.escape(user)}:#{URI.escape(pass)}@#{host}:#{port}/master_ui"),
                          {"name" => "ximapd",
                            "label" => "ximapd (#{Time.now})",
                            "submit" => "create",
                            "action" => "7"})

      @index = EstraierPure::Node.new()
      @index.set_url(nodeurl)
      @index.set_auth(user, pass)
      if @index.doc_num == -1
        raise "could not connect Estraier node: #{url}"
      end
    end

    def teardown
      system("estmaster stop #{@index_path} >/dev/null")
      sleep(1) # XXX: wait a bit.
    end

    def standby
      # noop
    end

    def relax
      # noop
    end

    def register(mail_data, filename)
      doc = EstraierPure::Document.new
      doc.add_attr("@uri", "file://" + File.expand_path(filename))
      doc.add_text(mail_data.text)
      mail_data.properties.each_pair do |name, value|
        doc.add_attr(name, value.to_s)
      end
      set_flags_internal(doc, mail_data.flags)
      ret = @index.put_doc(doc)
      raise "could not put mail to index: #{filename} (#{@index.status})" unless ret
      ret
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
      raise NotImplementedError
    end

    def get_old_flags(uid)
      raise NotImplementedError
    end

    def try_query(query)
      query(Query.parse(query))
    end

    private

    def open_index(*args)
      # noop
    end

    def close_index
      # noop
    end

    def get_uid(item_id)
      uid = @index.get_doc_attr(item_id, "uid").to_i
      raise "item_id:#{item_id} doesnot have uid" if uid.nil?
      uid
    end

    def get_doc(uid, item_id, item_obj)
      get_doc_internal(@index, uid, item_id, item_obj)
    end

    def get_doc_internal(index, uid, item_id, item_obj)
      if item_obj
        doc = item_obj
      elsif item_id
        doc = index.get_doc(item_id)
      elsif uid
        doc_id = query(PropertyEqQuery.new("uid", uid), index)[0]
        doc = index.get_doc(doc_id)
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
        result = @index.search(cond, 0)
	res = []
	for i in 0...result.doc_num
	  res.push(result.get_doc(i).attr("@id"))
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
        @cond = EstraierPure::Condition.new
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
