require "optparse"
require "find"
require "fileutils"

SCRIPT_NAME = File.basename($0)

$config = {
  "RUBY" => "/usr/bin/ruby",
  "prefix" => "/usr/local"
}

def create_file(filename, mode = 0644)
  open(filename + ".in") do |input|
    open(filename, "w") do |output|
      output.chmod(mode)
      for line in input
        s = line.gsub(/%([a-zA-z_]+)%/) {
          $config[$1]
        }
        output.print(s)
      end
    end
  end
end

def install_file(filename, dest, mode = 0644)
  FileUtils.mkdir_p(File.dirname(dest))
  FileUtils.cp(filename, dest)
  File.chmod(mode, dest)
end

def install_files(dir, target_dir, mode = 0644)
  Find.find(dir) do |filename|
    next if File.directory?(filename)
    dest = File.expand_path(filename[dir.length + 1 .. -1], target_dir)
    install_file(filename, dest, mode)
  end
end

options = OptionParser.new { |opts|
  opts.banner = "Usage: ruby #{SCRIPT_NAME} [options]"

  opts.separator("")

  opts.on("--ruby=PATH", String,
          "path to ruby [/usr/bin/ruby]") do |arg|
    $config["RUBY"] = arg
  end

  opts.on("--prefix=PREFIX", String,
          "install files in PREFIX [/usr/local]") do |arg|
    $config["prefix"] = arg
  end

  opts.separator("")

  opts.on("-h", "--help", "Show this help message.") do
    puts opts
    exit
  end
}
begin
  Dir.chdir(File.expand_path(File.dirname(__FILE__)))
  options.parse!
  $config["bindir"] = "#{$config['prefix']}/bin"
  $config["datadir"] = "#{$config['prefix']}/share/ximapd"
  $config["rubydir"] = "#{$config['datadir']}/ruby"
  $config["plugindir"] = "#{$config['datadir']}/plugins"
  create_file("ximapd", 0755)
  install_file("ximapd", "#{$config['bindir']}/ximapd", 0755)
  install_files("ruby", $config["rubydir"])
  install_files("plugins", $config["plugindir"])
rescue => e
  STDERR.printf("%s: %s\n", SCRIPT_NAME, e.message)
  exit(1)
end
