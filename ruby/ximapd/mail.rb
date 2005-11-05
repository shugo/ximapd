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
  class Mail
    include DataFormat

    attr_reader :mailbox, :seqno, :uid

    def initialize(config, mailbox, seqno, uid)
      @config = config
      @mailbox = mailbox
      @seqno = seqno
      @uid = uid
      @mail_store = @mailbox.mail_store
      @parsed_mail = nil
    end

    def envelope
      return envelope_internal(parsed_mail)
    end

    def path
      return @mailbox.get_mail_path(self)
    end

    def old_path
      dir1, dir2 = *[@uid].pack("v").unpack("H2H2")
      relpath = format("mail/%s/%s/%d", dir1, dir2, uid)
      return File.expand_path(relpath, @config["data_dir"])
    end

    def size
      begin
        return File.size(path)
      rescue Errno::ENOENT
        return File.size(old_path)
      end
    end

    def to_s
      open_file do |f|
        f.flock(File::LOCK_SH)
        return f.read
      end
    end

    def header(part = nil)
      if part
        return get_part(part).body.to_s.slice(/.*?\n\n/mn).gsub(/\n/, "\r\n")
      else
        open_file do |f|
          f.flock(File::LOCK_SH)
          return f.gets("\r\n\r\n")
        end
      end
    end

    def header_fields(fields, part = nil)
      pat = "^(?:" + fields.collect { |field|
        Regexp.quote(field)
      }.join("|") + "):.*(?:\r\n[ \t]+.*)*\r\n"
      re = Regexp.new(pat, true, "n")
      return header(part).scan(re).join + "\r\n"
    end

    def body_structure(extensible)
      return body_structure_internal(parsed_mail, extensible)
    end

    def multipart?
      mail = parsed_mail
      return mail.multipart?
    end

    def mime_header(part)
      return get_part(part).header.to_s.gsub(/\n/, "\r\n") + "\r\n"
    end

    def mime_body(part)
      if part.nil?
        return to_s
      else
        return get_part(part).body.to_s.gsub(/\n/, "\r\n")
      end
    end

    def delete
      begin
        File.unlink(path)
      rescue Errno::ENOENT
        File.unlink(old_path)
      end
    end

    private

    def open_file(mode = "r")
      begin
        File.open(path, mode) do |f|
          yield(f)
        end
      rescue Errno::ENOENT
        File.open(old_path, mode) do |f|
          yield(f)
        end
      end
    end

    def parsed_mail
      if @parsed_mail.nil?
        @parsed_mail = RMail::Parser.read(to_s.gsub(/\r\n/, "\n"))
      end
      return @parsed_mail
    end

    def get_part(part)
      part_numbers = part.split(/\./).collect { |i| i.to_i - 1 }
      return get_part_internal(parsed_mail, part_numbers)
    end

    def get_part_internal(mail, part_numbers)
      n = part_numbers.shift
      if /message\/rfc822/n.match(mail.header.content_type)
        mail = RMail::Parser.read(mail.body)
      end
      if !mail.multipart? && n == 0
        m = mail
      else
        m = mail.part(n)
      end
      if part_numbers.empty?
        return m
      end
      return get_part_internal(m, part_numbers)
    end

    def envelope_internal(mail)
      s = "("
      s.concat(quoted(mail.header["date"]))
      s.concat(" ")
      s.concat(quoted(mail.header["subject"]))
      s.concat(" ")
      s.concat(envelope_addrs(mail.header.from))
      s.concat(" ")
      s.concat(envelope_addrs(mail.header.from))
      s.concat(" ")
      if mail.header.reply_to.empty?
        s.concat(envelope_addrs(mail.header.from))
      else
        s.concat(envelope_addrs(mail.header.reply_to))
      end
      s.concat(" ")
      s.concat(envelope_addrs(mail.header.to))
      s.concat(" ")
      s.concat(envelope_addrs(mail.header.cc))
      s.concat(" ")
      s.concat(envelope_addrs(mail.header.bcc))
      s.concat(" ")
      s.concat(quoted(mail.header["in-reply-to"]))
      s.concat(" ")
      s.concat(quoted(mail.header["message-id"]))
      s.concat(")")
      return s
    end

    def envelope_addrs(addrs)
      if addrs.nil? || addrs.empty?
        return "NIL"
      else
        return "(" + addrs.collect { |addr|
          envelope_addr(addr)
        }.join(" ") + ")"
      end
    end

    def envelope_addr(addr)
      name = addr.display_name
      adl = nil
      if addr.local
        mailbox = addr.local.tr('"', '')
      else
        mailbox = nil
      end
      host = addr.domain
      return format("(%s %s %s %s)",
                    quoted(name), quoted(adl), quoted(mailbox), quoted(host))
    end

    def body_structure_internal(mail, extensible)
      ary = []
      if /message\/rfc822/n.match(mail.header.content_type)
        body = RMail::Parser.read(mail.body)
        ary.push(quoted("MESSAGE"))
        ary.push(quoted("RFC822"))
        ary.push(body_fields(mail, extensible))
        ary.push(envelope_internal(body))
        ary.push(body_structure_internal(body, extensible))
        ary.push(mail.body.to_a.length.to_s)
      elsif mail.multipart?
        parts = mail.body.collect { |part|
          body_structure_internal(part, extensible)
        }.join
        ary.push(parts)
        ary.push(quoted(upcase(mail.header.subtype)))
        if extensible
          ary.push(body_ext_mpart(mail))
        end
      else
        ary.push(quoted(upcase(mail.header.media_type)))
        ary.push(quoted(upcase(mail.header.subtype)))
        ary.push(body_fields(mail, extensible))
        if mail.header.media_type == "text"
          ary.push(mail.body.to_a.length.to_s)
        end
        if extensible
          ary.push(body_ext_1part(mail))
        end
      end
      return "(" + ary.join(" ") + ")"
    end

    def body_fields(mail, extensible)
      fields = []
      params = "(" + mail.header.params("content-type", {}).collect { |k, v|
        v.gsub!(/\s/,"")
        format("%s %s", quoted(upcase(k)), quoted(v))
      }.join(" ") + ")"
      if params == "()"
        fields.push("NIL")
      else
        fields.push(params)
      end
      fields.push("NIL")
      fields.push("NIL")
      content_transfer_encoding =
        (mail.header["content-transfer-encoding"] || "7BIT").to_s.upcase
      fields.push(quoted(content_transfer_encoding))
      fields.push(mail.body.gsub(/\n/, "\r\n").length.to_s)
      return fields.join(" ")
    end

    def body_ext_mpart(mail)
      exts = []
      exts.push(body_fld_param(mail))
      exts.push(body_fld_dsp(mail))
      exts.push("NIL")
    end

    def body_ext_1part(mail)
      exts = []
      exts.push("NIL")
      exts.push(body_fld_dsp(mail))
      exts.push("NIL")
      return exts.join(" ")
    end

    def body_fld_param(mail)
      unless mail.header.field?("content-type")
        return "NIL"
      end
      params = mail.header.params("content-type", {}).collect { |k, v|
        v.gsub!(/\s/,"")
        format("%s %s", quoted(upcase(k)), quoted(v))
      }
      if params.empty?
        return "NIL"
      else
        return "(" + params.join(" ") + ")"
      end
    end

    def body_fld_dsp(mail)
      unless mail.header.field?("content-disposition")
        return "NIL"
      end
      params = mail.header.params("content-disposition", {}).collect { |k, v|
        v.gsub!(/\s/,"")
        format("%s %s", quoted(upcase(k)), quoted(v))
      }
      if params.empty?
        p = "NIL"
      else
        p = "(" + params.join(" ") + ")"
      end
      value = mail.header["content-disposition"].sub(/;.*/mn, "")
      return format("(%s %s)", quoted(upcase(value)), p)
    end

    def upcase(s)
      if s.nil?
        return s
      end
      return s.upcase
    end
  end

  class IndexedMail < Mail
    attr_reader :item_id
    attr_reader :indexed_obj

    def initialize(config, mailbox, seqno, uid,
                   item_id = nil, internal_date = nil,
                   indexed_obj = nil)
      super(config, mailbox, seqno, uid)
      @item_id = item_id
      if internal_date
        @internal_date = DateTime.strptime(internal_date[0, 19] + " " +
                                           TIMEZONE,
                                           "%Y-%m-%dT%H:%M:%S %z")
      else
        @internal_date = nil
      end
      @indexed_obj = indexed_obj
    end

    def internal_date
      unless @internal_date
        mail = @mailbox.uid_fetch([@uid])[0]
        @internal_date = mail.internal_date
        @item_id = mail.item_id
        @indexed_obj = mail.indexed_obj
      end
      return @internal_date
    end

    def flags(get_recent = true)
      s = @mail_store.backend.get_flags(@uid, @item_id, @indexed_obj)
      if get_recent && uid > @mailbox["last_peeked_uid"]
        if s.empty?
          return "\\Recent"
        else
          return "\\Recent " + s
        end
      else
        return s
      end
    end

    def flags=(s)
      result = @mail_store.backend.set_flags(@uid, @item_id, @indexed_obj, s)
      @indexed_obj = nil
      return result
    end

    def delete
      super
      @mail_store.open_backend do |backend|
        backend.delete_flags(@uid, @item_id, @indexed_obj)
        @indexed_obj =  nil
        backend.delete(@uid, @item_id)
      end
    end
  end

  class StaticMail < Mail
    def internal_date
      return File.mtime(path)
    end

    def flags(get_recent = true)
      @mailbox.open_flags_db do |db|
        s = db[@uid.to_s].to_s
        if get_recent && uid > @mailbox["last_peeked_uid"]
          if s.empty?
            return "\\Recent"
          else
            return "\\Recent " + s
          end
        else
          return s
        end
      end
    end

    def flags=(s)
      @mailbox.open_flags_db do |db|
        db[@uid.to_s] = s
      end
    end

    def delete
      super
      @mailbox.open_flags_db do |db|
        db.delete(@uid.to_s)
      end
    end
  end
end
