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

    module QueryFormat
      module_function

      def quote_query(s)
        return format('"%s"', s.gsub(/[\\"]/n, "\\\\\\&"))
      end
    end

    extend QueryFormat
    class << self
      def make_list_query(list_name)
        {"main" => format("x-ml-name = %s",
                          quote_query(list_name)),
         "sub" => nil}
      end

      def make_default_query(mailbox_id)
        {"main" => format('mailbox-id = %d', mailbox_id), "sub" => nil}
      end

      def make_query(mailbox_name)
        {"main" => mailbox_name, "sub" => nil}
      end
    end

    def initialize(mail_store)
      super(mail_store)
      @flags_db_path = File.expand_path("flags.sdbm", @path)
      @flags_db = nil
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
      result = @index.search(mailbox["query"]["main"],
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
      additional_queries = sequence_set.collect { |seq_number|
        case seq_number
        when Range
          q = ""
          if seq_number.first > 1
            q += format(" uid >= %d", seq_number.first)
          end
          if seq_number.last != -1
            q += format(" uid <= %d", seq_number.last)
          end
          q
        else
          format("uid = %d", seq_number)
        end
      }.reject { |q| q.empty? }
      if additional_queries.empty?
        query = mailbox["query"]["main"]
      else
        query = mailbox["query"]["main"] +
          " ( " + additional_queries.join(" | ") + " )"
      end
      result = @index.search(query, options)
      return result.items.collect { |i|
        uid = i.properties[0]
        IndexedMail.new(@config, mailbox, uid, uid, i.doc_id, i.properties[1])
      }
    end

    def mailbox_status(mailbox)
      mailbox_status = MailboxStatus.new

      result = @index.search(mailbox["query"]["main"],
                             "properties" => ["uid"],
                             "start_no" => 0)
      mailbox_status.messages = result.hit_count
      mailbox_status.unseen = result.items.select { |i|
        !/\\Seen\b/ni.match(get_flags(i.properties[0].to_s, nil, nil))
      }.length
      query = format("%s uid > %d",
                      mailbox["query"]["main"], mailbox["last_peeked_uid"])
      result = @index.search(query,
                             "properties" => ["uid"],
                             "start_no" => 0,
                             "num_items" => Rast::RESULT_MIN_ITEMS)
      mailbox_status.recent = result.hit_count

      mailbox_status
    end

    # returns Rast::Result#items.to_a
    def query(mailbox, query)
    end

    def uid_search(mailbox, query)
      options = {
        "properties" => ["uid"],
        "start_no" => 0,
        "num_items" => Rast::RESULT_ALL_ITEMS,
        "sort_method" => Rast::SORT_METHOD_PROPERTY,
        "sort_property" => "uid",
        "sort_order" => Rast::SORT_ORDER_ASCENDING
      }
      q = query["main"] + " " + mailbox["query"]["main"]
      result = @index.search(q, options)
      return result.items.collect { |i| i.properties[0] }
    end

    def uid_search_by_keys(mailbox, keys)
      query = keys.collect { |key| key.to_query["main"] }.reject { |q|
        q.empty?
      }.join(" ")
      query = "uid > 0 " + query if /\A\s*!/ =~ query
      uids = uid_search(mailbox, {"main" => query, "sub" => nil})
      for key in keys
        uids = key.select(uids)
      end
      uids
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
        @flags_db[uid.to_s]
      else
        nil
      end
    end

    def try_query(query)
      @index.search(query["main"], "num_items" => Rast::RESULT_MIN_ITEMS)
    end

    class NullSearchKey
      def to_query
        return {"main" => "", "sub" => nil}
      end

      def select(uids)
        return uids
      end

      def reject(uids)
        return uids
      end
    end

    class BodySearchKey < NullSearchKey
      def initialize(value)
        @value = value
      end

      def to_query
        return {"main" => @value, "sub" => nil}
      end
    end

    class HeaderSearchKey < NullSearchKey
      include QueryFormat

      def initialize(name, value)
        @name = name
        @value = value
      end

      def to_query
        case @name
        when "subject", "from", "to", "cc", "bcc"
          return {"main" => format("%s : %s", @name, quote_query(@value)),
                  "sub" => nil}
        when "x-ml-name", "x-mail-count"
          return {"main" => format("%s = %s", @name, quote_query(@value)),
                  "sub" => nil}
        else
          super
        end
      end
    end

    class FlagSearchKey < NullSearchKey
      def initialize(mail_store, flag)
        @mail_store = mail_store
        @flag_re = Regexp.new(Regexp.quote(flag) + "\\b", true, "n")
      end

      def select(uids)
        @mail_store.open_backend do |index|
          return uids.select { |uid|
            @flag_re.match(index.get_flags(uid, nil, nil))
          }
        end
      end

      def reject(uids)
        @mail_store.open_backend do |index|
          return uids.reject { |uid|
            @flag_re.match(index.get_flags(uid, nil, nil))
          }
        end
      end
    end

    class NoFlagSearchKey < FlagSearchKey
      alias super_select select
      alias super_reject reject
      alias select super_reject
      alias reject super_select
    end

    class KeywordSearchKey < NullSearchKey
      def initialize(mail_store, flag)
        @mail_store = mail_store
        if /\A\w/n.match(flag)
          s = "\\b"
        else
          s = ""
        end
        @flag_re = Regexp.new(s + Regexp.quote(flag) + "\\b", true, "n")
      end

      def select(uids)
        @mail_store.open_backend do |index|
          return uids.select { |uid|
            @flag_re.match(index.get_flags(uid, nil, nil))
          }
        end
      end

      def reject(uids)
        @mail_store.open_backend do |index|
          return uids.reject { |uid|
            @flag_re.match(index.get_flags(uid, nil, nil))
          }
        end
      end
    end

    class NoKeywordSearchKey < KeywordSearchKey
      alias super_select select
      alias super_reject reject
      alias select super_reject
      alias reject super_select
    end

    class SequenceNumberSearchKey < NullSearchKey
      def initialize(sequence_set)
        @sequence_set = sequence_set
      end

      def to_query
        raise NotImplementedError.new("sequence number search is not implemented")
      end
    end

    class UidSearchKey < NullSearchKey
      def initialize(sequence_set)
        @sequence_set = sequence_set
      end

      def to_query
        if @sequence_set.empty?
          super
        end
        q = "( " + @sequence_set.collect { |i|
          case i
          when Range
            if i.last == -1
              format("uid >= %d", i.first)
            else
              format("%d <= uid <= %d", i.first, i.last)
            end
          else
            format("uid = %d", i)
          end
        }.join(" | ") + " )"
        return {"main" => q, "sub" => nil}
      end
    end

    class NotSearchKey
      def initialize(key)
        @key = key
      end

      def to_query
        q = @key.to_query
        if q["main"].empty?
          return {"main" => "", "sub" => nil}
        else
          return {"main" => format("! ( %s )", q["main"]), "sub" => nil}
        end
      end

      def select(uids)
        return @key.reject(uids)
      end

      def reject(uids)
        return @key.select(uids)
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
        return {"main" => format("internal-date < %s", date_str(@date)),
                "sub" => nil}
      end
    end

    class OnSearchKey < DateSearchKey
      def to_query
        date_end = @date + 86400
        return {"main" => format("%s <= internal-date < %s",
                                 date_str(@date), date_str(date_end)),
                "sub" => nil}
      end
    end

    class SinceSearchKey < DateSearchKey
      def to_query
        date = @date + 86400
        return {"main" => format("internal-date >= %s", date_str(date)), "sub" => nil}
      end
    end

    class SentbeforeSearchKey < DateSearchKey
      def to_query
        return {"main" => format("date < %s", date_str(@date)), "sub" => nil}
      end
    end

    class SentonSearchKey < DateSearchKey
      def to_query
        date_end = @date + 86400
        return {"main" => format("%s <= date < %s",
                                 date_str(@date), date_str(date_end)),
                "sub" => nil}
      end
    end

    class SentsinceSearchKey < DateSearchKey
      def to_query
        date = @date + 86400
        return {"main" => format("date >= %s", date_str(date)), "sub" => nil}
      end
    end

    class LargerSearchKey < NullSearchKey
      def initialize(size_str)
        @size_str = size_str
      end

      def to_query
        return {"main" => format("size > %s", @size_str), "sub" => nil}
      end
    end

    class SmallerSearchKey < LargerSearchKey
      def to_query
        return {"main" => format("size < %s", @size_str), "sub" => nil}
      end
    end

    class OrSearchKey < NullSearchKey
      def initialize(key1, key2)
        @keys = [key1, key2]
      end

      def to_query
        qs = []
        @keys.each do |key|
          q = key.to_query
          if q["main"].empty?
            return ""
          elsif /\A\s*!/ =~ q["main"]
            qs << "uid > 0 " + q["main"]
          else
            qs << q["main"]
          end
        end

        return {"main" => format("( %s )", qs.join(" | ")), "sub" => nil}
      end
    end

    class GroupSearchKey < NullSearchKey
      def initialize(keys)
        @keys = keys
      end

      def to_query
        qs = []
        @keys.each do |key|
          q = key.to_query
          if q["main"].empty?
          elsif /\A\s*!/ =~ q["main"]
            qs << "uid > 0 " + q["main"]
          else
            qs << q["main"]
          end
        end

        return {"main" => format("( %s )", qs.join(" & ")), "sub" => nil}
      end
    end

    class EndGroupSearchKey
    end
  end
end
