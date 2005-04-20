require "test/unit"

runner = Test::Unit::AutoRunner.new(true)
if !runner.process_args(ARGV)
  runner.to_run << File.dirname(__FILE__)
end
if runner.pattern.empty?
  runner.pattern = [/-test.rb\z/]
end
runner.exclude.push(/\b.svn\b/)
exit runner.run

# vim: set filetype=ruby expandtab sw=2 :
