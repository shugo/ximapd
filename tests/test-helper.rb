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

require "test/unit"
require "stringio"
require "tmpdir"
require "logger"
require "pp"

def require_plugin(name)
  filename = File.expand_path("../plugins/#{name}.rb", File.dirname(__FILE__))
  open(filename) do |f|
    Ximapd.class_eval(f.read)
  end
end

def mkdtemp(prefix, mode = 0700)
  retry_count = 0
  begin
    dir = File.join(Dir.tmpdir, 
                    "#{prefix}-#{$$}.#{rand(10000)}")
    Dir.mkdir(dir, mode)
    return dir
  rescue Errno::EEXIST
    if retry_count < 3
      retry_count += 1
      retry
    else
      raise "can't create #{dir}"
    end
  end
end

class Time
  @spoof_now = nil

  class << self
    alias real_now now
    attr_accessor :spoof_now

    klass = self

    define_method(:use_spoof_now) do
      klass.send(:alias_method, :now, :spoof_now)
    end

    define_method(:use_real_now) do
      klass.send(:alias_method, :now, :real_now)
    end

    def replace_now(time)
      self.spoof_now = time
      use_spoof_now
      begin
        yield
      ensure
        use_real_now
      end
    end
  end
end

module XimapdTestMixin
  def setup
    @tmpdir = mkdtemp("ximapd-test")
    @config = {
      "index_engine" => "rast",
      "user" => "foo",
      "password" => "bar",
      "data_dir" => File.expand_path("data", @tmpdir),
      "logger" => Ximapd::NullObject.new
    }
  end

  def teardown
    system("rm", "-rf", @tmpdir)
  end
end

$:.unshift(File.expand_path("../ruby", File.dirname(__FILE__)))
require "ximapd"

# vim: set filetype=ruby expandtab sw=2 :
