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

require "rast"

module Rast
  unless defined?(RESULT_ALL_ITEMS)
    if Rast::VERSION < "0.1.0"
      RESULT_ALL_ITEMS = 0
    else
      RESULT_ALL_ITEMS = -1
    end
  end
  if Rast::VERSION < "0.1.0"
    RESULT_MIN_ITEMS = 1
  else
    RESULT_MIN_ITEMS = 0
  end
end

class Ximapd
  class RastBackend < Backend
    INDEX_OPTIONS = {
      "encoding" => "utf8",
      "preserve_text" => false,
      "properties" => [
        {
          "name" => "uid",
          "type" => Rast::PROPERTY_TYPE_UINT,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => true,
        },
        {
          "name" => "size",
          "type" => Rast::PROPERTY_TYPE_UINT,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "internal-date",
          "type" => Rast::PROPERTY_TYPE_DATE,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "flags",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "mailbox-id",
          "type" => Rast::PROPERTY_TYPE_UINT,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "date",
          "type" => Rast::PROPERTY_TYPE_DATE,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "subject",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => true,
          "unique" => false,
        },
        {
          "name" => "from",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "to",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "cc",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "bcc",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => false,
          "text_search" => true,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "x-ml-name",
          "type" => Rast::PROPERTY_TYPE_STRING,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        },
        {
          "name" => "x-mail-count",
          "type" => Rast::PROPERTY_TYPE_UINT,
          "search" => true,
          "text_search" => false,
          "full_text_search" => false,
          "unique" => false,
        }
      ]
    }
    DEFAULT_SYNC_THRESHOLD_CHARS = 500000

    attr_reader :result_selecting_visitor, :result_rejecting_visitor

    def initialize(mail_store)
      super(mail_store)
      @flags_db_path = File.expand_path("flags.sdbm", @path)
      @flags_db = nil
      @query_compiling_visitor = QueryCompilingVisitor.new
      @result_selecting_visitor = ResultSelectingVisitor.new(self)
      @result_rejecting_visitor = ResultRejectingVisitor.new(self)
    end

    def setup
      unless File.exist?(@index_path)
        Rast::DB.create(@index_path, INDEX_OPTIONS)
      end
    end

    def standby
      @flags_db = SDBM.open(@flags_db_path)
    end

    def relax
       @flags_db.close
       @flags_db = nil
    end

    def open(*args)
      if args.empty?
        flags = Rast::DB::RDWR
      else
        flags = args.last
      end
      @index = Rast::DB.open(@index_path, flags,
                             "sync_threshold_chars" => @config["sync_threshold_chars"] || DEFAULT_SYNC_THRESHOLD_CHARS)
    end

    def close
      @index.close
    end

    def register(mail_data, filename)
      doc_id = @index.register(mail_data.text, mail_data.properties)
      set_flags(mail_data.uid, doc_id, nil, mail_data.flags)
    end

    def get_flags(uid, item_id, item_obj)
      @flags_db[uid.to_s]
    end

    def set_flags(uid, item_id, item_obj, flags)
      @flags_db[uid.to_s] = flags
    end

    def delete_flags(uid, item_id, item_obj)
      @flags_db.delete(uid.to_s)
    end

    def delete(uid, item_id)
      @index.delete(item_id)
    end

    def fetch(mailbox, sequence_set)
      result = search_query(mailbox.query,
                            "properties" => ["uid", "internal-date"],
                            "start_no" => 0,
                            "num_items" => Rast::RESULT_ALL_ITEMS,
                            "sort_method" => Rast::SORT_METHOD_PROPERTY,
                            "sort_property" => "uid",
                            "sort_order" => Rast::SORT_ORDER_ASCENDING)
      mails = []
      sequence_set.each do |seq_number|
        case seq_number
        when Range
          first = seq_number.first
          last = seq_number.last == -1 ? result.items.length : seq_number.last
          for i in first .. last
            item = result.items[i - 1]
            mail = IndexedMail.new(@config, mailbox, i, item.properties[0],
                                    item.doc_id, item.properties[1])
            mails.push(mail)
          end
        else
          item = result.items[seq_number - 1]
          next if item.nil?
          mail = IndexedMail.new(@config, mailbox, seq_number,
                                  item.properties[0], item.doc_id,
                                  item.properties[1])
          mails.push(mail)
        end
      end
      return mails
    end

    def uid_fetch(mailbox, sequence_set)
      options = {
        "properties" => ["uid", "internal-date"],
        "start_no" => 0,
        "num_items" => Rast::RESULT_ALL_ITEMS,
        "sort_method" => Rast::SORT_METHOD_PROPERTY,
        "sort_property" => "uid",
        "sort_order" => Rast::SORT_ORDER_ASCENDING
      }
      query = mailbox.query
      additional_queries = sequence_set.collect { |seq_number|
        case seq_number
        when Range
          q = NullQuery.new
          if seq_number.first > 1
            q &= PropertyGeQuery.new("uid", seq_number.first)
          end
          if seq_number.last != -1
            q &= PropertyLeQuery.new("uid", seq_number.last)
          end
          q
        else
          PropertyEqQuery.new("uid", seq_number)
        end
      }.reject { |q| q.null? }
      unless additional_queries.empty?
        query &= OrQuery.new(additional_queries)
      end
      result = search_query(query, options)
      return result.items.collect { |i|
        uid = i.properties[0]
        IndexedMail.new(@config, mailbox, uid, uid, i.doc_id, i.properties[1])
      }
    end

    def mailbox_status(mailbox)
      mailbox_status = MailboxStatus.new

      result = search_query(mailbox.query,
                            "properties" => ["uid"],
                            "start_no" => 0)
      mailbox_status.messages = result.hit_count
      mailbox_status.unseen = result.items.select { |i|
        !/\\Seen\b/ni.match(get_flags(i.properties[0].to_s, nil, nil))
      }.length
      query = mailbox.query &
        PropertyGtQuery.new("uid", mailbox["last_peeked_uid"])
      result = search_query(query,
                            "properties" => ["uid"],
                            "start_no" => 0,
                            "num_items" => Rast::RESULT_MIN_ITEMS)
      mailbox_status.recent = result.hit_count

      mailbox_status
    end

    # returns Rast::Result#items.to_a
    def query(mailbox, query)
    end

    def uid_search(query)
      result = search_query(query,
                            "properties" => ["uid"],
                            "start_no" => 0,
                            "num_items" => Rast::RESULT_ALL_ITEMS,
                            "sort_method" => Rast::SORT_METHOD_PROPERTY,
                            "sort_property" => "uid",
                            "sort_order" => Rast::SORT_ORDER_ASCENDING)
      uids = result.items.collect { |i|
        i.properties[0]
      }
      return query.accept(@result_selecting_visitor, uids)
    end

    def rebuild_index(*args)
      if args.empty?
        flags = Rast::DB::RDWR
      else
        flags = args.last
      end
      old_index_path = @index_path + ".old"

      @old_index = nil
      begin
        File.rename(@index_path, old_index_path)
        @old_index = Rast::DB.open(old_index_path, flags,
                                   "sync_threshold_chars" => @config["sync_threshold_chars"] || DEFAULT_SYNC_THRESHOLD_CHARS)
      rescue Errno::ENOENT
      end
      begin
        @index = Rast::DB.create(@index_path, INDEX_OPTIONS)
        yield
        FileUtils.rm_rf(old_index_path)
      ensure
        @old_index = nil
      end
    end

    def get_old_flags(uid)
      if @old_index
        return @flags_db[uid.to_s]
      else
        return nil
      end
    end

    def try_query(query)
      return search_query(Query.parse(query),
                          "num_items" => Rast::RESULT_MIN_ITEMS)
    end

    private

    def search_query(query, options)
      s = query.accept(@query_compiling_visitor)
      return @index.search(s, options)
    end

    class QueryCompilingVisitor < QueryVisitor
      def visit_term_query(query)
        return quote_query(query.value)
      end

      def visit_property_pe_query(query)
        return compile_property_query(query, ":")
      end

      def visit_property_eq_query(query)
        return compile_property_query(query, "=")
      end

      def visit_property_lt_query(query)
        return compile_property_query(query, "<")
      end

      def visit_property_gt_query(query)
        return compile_property_query(query, ">")
      end

      def visit_property_le_query(query)
        return compile_property_query(query, "<=")
      end

      def visit_property_ge_query(query)
        return compile_property_query(query, ">=")
      end

      def visit_and_query(query)
        return compile_composite_query(query, "&")
      end

      def visit_or_query(query)
        return compile_composite_query(query, "|")
      end

      def visit_diff_query(query)
        return compile_composite_query(query, "-")
      end

      private

      def visit_default(query)
        return ""
      end

      def compile_property_query(query, operator)
        return format('%s %s %s',
                      query.name, operator, quote_query(query.value))
      end

      def compile_composite_query(query, operator)
        return query.operands.collect { |operand|
          s = operand.accept(self)
          if operand.composite?
            "( " + s + " )"
          else
            s
          end
        }.reject { |s| s.empty? }.join(" " + operator + " ")
      end

      def quote_query(s)
        return format('"%s"', s.gsub(/[\\"]/n, "\\\\\\&"))
      end
    end

    class ResultVisitor < QueryVisitor
      def initialize(backend)
        @backend = backend
      end

      private

      def visit_default(query, uids)
        return uids
      end

      def select_flag_query(query, uids)
        re = query.regexp
        return uids.select { |uid|
          re.match(@backend.get_flags(uid, nil, nil))
        }
      end

      def reject_flag_query(query, uids)
        re = query.regexp
        return uids.reject { |uid|
          re.match(@backend.get_flags(uid, nil, nil))
        }
      end
    end

    class ResultSelectingVisitor < ResultVisitor
      def visit_flag_query(query, uids)
        return select_flag_query(query, uids)
      end

      def visit_no_flag_query(query, uids)
        return reject_flag_query(query, uids)
      end

      def visit_and_query(query, uids)
        result = uids
        for q in query.operands
          result = q.accept(self, result)
        end
        return result
      end

      def visit_diff_query(query, uids)
        result = uids
        first, *rest = query.operands
        result = first.accept(self, result)
        for q in rest
          result = q.accept(@backend.result_rejecting_visitor, result)
        end
        return result
      end
    end

    class ResultRejectingVisitor < ResultVisitor
      def visit_flag_query(query, uids)
        return reject_flag_query(query, uids)
      end

      def visit_no_flag_query(query, uids)
        return select_flag_query(query, uids)
      end

      def visit_and_query(query, uids)
        result = uids
        for q in query.operands
          result = q.accept(self, result)
        end
        return result
      end

      def visit_diff_query(query, uids)
        result = uids
        first, *rest = query.operands
        result = first.accept(self, result)
        for q in rest
          result = q.accept(@backend.result_selecting_visitor, result)
        end
        return result
      end
    end
  end
end
