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
  class Sequence
    def initialize(path, initial_value = 1)
      @path = path
      @new_path = path + ".new"
      @tmp_path = path + ".tmp"
      @initial_value = initial_value
    end

    def current
      File.open(@path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_SH)
        return get_current_value(f)
      end
    end

    def current=(value)
      File.open(@path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        write_value(f, value)
        return value
      end
    end

    def next
      File.open(@path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        value = get_next_value(f)
        write_value(f, value)
        return value
      end
    end

    def peek_next
      File.open(@path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_SH)
        return get_next_value(f)
      end
    end

    private

    def get_current_value(f)
      begin
        s = File.read(@new_path)
        File.unlink(@new_path)
      rescue Errno::ENOENT
        s = f.read
      end
      if s.empty?
        return nil
      end
      return s.to_i
    end

    def get_next_value(f)
      n = get_current_value(f)
      if n.nil?
        return @initial_value
      end
      return n + 1
    end

    def write_value(f, value)
      File.open(@tmp_path, "w") do |tmp|
        tmp.print(value.to_s)
      end
      File.rename(@tmp_path, @new_path)
      f.rewind
      f.print(value.to_s)
      f.truncate(f.pos)
      f.fsync
      File.unlink(@new_path)
    end
  end
end
