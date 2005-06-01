dir = File.expand_path("..", File.dirname(__FILE__))
$:.unshift(File.expand_path("..", File.dirname(__FILE__)))

require "test/unit"
require "stringio"
require "tmpdir"
require "logger"
require "pp"

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

ximapd = File.expand_path("../ximapd", File.dirname(__FILE__))
load(ximapd)
