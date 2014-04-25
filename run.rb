require_relative 'fwsm'
require_relative 'syslog'
require_relative 'committer'
require 'yaml'

abort "usage: ruby fwsm.rb config" if ARGV.size < 1

CONFIG=ARGV[0]

puts "config: '%s'" % [CONFIG]
config = YAML::load(File.open(CONFIG))

manager = FWSMConfigManager.new(
	config[:fwsm][:host],
	config[:fwsm][:user],
	config[:fwsm][:pass],
	config[:committer]
)
syslog = FWSMChangePublisher.new(config[:syslog][:address],config[:syslog][:port], config[:context_map])
syslog.subscribe(FWSMChangeAggregator.new(manager))


syslog.run
