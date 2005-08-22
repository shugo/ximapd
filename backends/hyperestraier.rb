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

    private
    def initialize()
      @db = Database.new()
    end

    public
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
        HyperEstraier.err_msg(errno)
      else
        '(unknown error)'
      end
    end
  end
end

class Ximapd
  class HyperEstraierBackend < Backend
    module QueryFormat
      module_function

      def quote_query(s)
        format('"%s"', query.gsub(/[\\"]/n, "\\\\\\&"))
      end
    end

    private

    extend QueryFormat
    class << self
      def make_list_query(list_name)
        {"main" => "",
          "sub" => [format("x-ml-name STREQ %s", list_name)]}
      end
      public :make_list_query

      def make_default_query(mailbox_id)
        {"main" => "",
          "sub" => [format("mailbox-id NUMEQ %d", mailbox_id)]}
      end
      public :make_default_query

      def make_query(mailbox_name)
        sub_query = []
        query = mailbox_name.gsub(/\(([\)]*)\)/) {
          sub_query << $1.strip
          " "
        }
        {"main" => query.strip, "sub" => sub_query}
      end
      public :make_query
    end

    def initialize(mail_store)
      super(mail_store)
    end

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

    def open(*args)
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
    public :open

    def close
      @index.close
    end
    public :close

    def register(mail_data, filename)
      doc = HyperEstraier::Document.new
      doc.add_attr("@uri", "file://" + File.expand_path(filename))
      doc.add_text(mail_data.text)
      mail_data.properties.each_pair do |name, value|
        case name
        when "size"
          doc.add_attr("@size", value.to_s)
        when "internal-date"
          doc.add_attr("@cdate", value.to_s)
          doc.add_attr("@mdate", value.to_s)
        when "subject"
          doc.add_attr("@title", value.to_s)
        when "date"
          doc.add_attr(name, value.to_s)
        else
          doc.add_attr(name, value.to_s)
        end
      end
      doc.add_attr("flags", mail_data.flags)
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
        cond = HyperEstraier::Condition.new
        cond.add_attr("uid NUMEQ #{uid}")
        doc_id = index.search(cond, 0)[0]
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
      doc = get_doc(uid, item_id, item_obj)
      begin
        doc.attr("flags").scan(/[^<>\s]+/).join(" ")
      rescue ArgumentError
        ""
      end
    end
    public :get_flags

    def set_flags(uid, item_id, item_obj, flags)
      doc = get_doc(uid, item_id, item_obj)
      doc.add_attr("flags", "<" + flags.strip.split(/\s+/).join("><") + ">")
      @index.edit_doc(doc)
    end
    public :set_flags

    def delete_flags(uid, item_id, item_obj)
      set_flags(uid, item_id, item_obj, "")
    end
    public :delete_flags

    def delete(uid, item_id)
      @index.out_doc(item_id)
    end
    public :delete

    def fetch(mailbox, sequence_set)
      result = query(mailbox, {"main" => "", "sub" => []})
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
                                   doc.attr("@mdate"), doc)
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
                                 doc.attr("@mdate"), doc)
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

      mails = []
      result = []
      sequence_set.collect do |i|
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
        result |= query(mailbox, {"main" => "", "sub" => sq})
      end

      result.each do |item_id|
        doc = get_doc(nil, item_id, nil)
        uid = doc.attr("uid").to_i
        mails << IndexedMail.new(@config, mailbox, uid, uid,
                                 item_id, doc.attr("@mdate"),
                                 doc)
      end

      mails
    end
    public :uid_fetch

    def mailbox_status(mailbox)
      mailbox_status = MailboxStatus.new

      cond = HyperEstraier::Condition.new()
      if mailbox["query"]["main"] && !mailbox["query"]["main"].empty?
        cond.set_phrase(mailbox["query"]["main"])
      end
      if mailbox["query"]["sub"]
        mailbox["query"]["sub"].each { |eq| cond.add_attr(eq) }
      end
      result = @index.search(cond, 0)
      mailbox_status.messages = result.length
      mailbox_status.unseen = result.select { |item_id|
        !/\\Seen\b/ni.match(get_flags(nil, item_id, nil))
      }.length
      cond.add_attr("uid NUMGT %d"% mailbox["last_peeked_uid"])
      result = @index.search(cond, 0)
      mailbox_status.recent = result.length
      mailbox_status
    end
    public :mailbox_status

    def query(mailbox, query)
      cond = HyperEstraier::Condition.new()
      cond.set_order("uid NUMA")

      if mailbox["query"]["main"].empty?
        q = query["main"]
      elsif query["main"].empty?
        q = mailbox["query"]["main"]
      else
        q = query["main"] + " " + mailbox["query"]["main"]
      end
      if q && /\S/ =~ q
        cond.set_phrase(q)
      end

      if query["sub"]
        query["sub"].each { |eq| cond.add_attr(eq) }
      end
      if mailbox["query"]["sub"]
        mailbox["query"]["sub"].each { |eq| cond.add_attr(eq) }
      end
      cond.set_order("uid NUMA")
      cond.set_options(HyperEstraier::Condition::CONDSIMPLE)

      result = @index.search(cond, 0)
      result.to_a
    end
    public :query

    def uid_search(mailbox, query)
      result = query(mailbox, query)
      result.collect { |item_id| get_uid(item_id) }
    end
    public :uid_search

    def query_by_keys(mailbox, keys)
      rest_keys = []
      q = {"main" => "", "sub" => []}
      for key in keys
        if kq = key.to_query
          unless kq["main"].empty?
            q["main"] << " "
            q["main"] << kq["main"]
          end
          q["sub"] |= kq["sub"]
        else
          rest_keys << key
        end
      end

      result = query(mailbox, q)
      for key in rest_keys
        result = key.exec(self, mailbox, result)
      end

      result
    end
    public :query_by_keys

    def uid_search_by_keys(mailbox, keys)
      query_by_keys(mailbox, keys).collect { |item_id| get_uid(item_id) }
    end
    public :uid_search_by_keys

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
      cond = HyperEstraier::Condition.new() 
      cond.set_max(1)
      cond.set_phrase(query["main"])       
      if query["sub"]
        query["sub"].each { |eq| cond.add_attr(eq) }
      end 
      r = @index.search(cond, 0)
      unless r.kind_of?(HyperEstraier::IntVector)
        raise "search failed for #{query["main"].dump} (#{query["sub"].collect { |eq| eq.dump }.join(', ')})"
      end   
      true
    end
    public :try_query

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
