require_relative 'fwsm'
require_relative 'syslog'
require_relative 'committer'
require 'yaml'

abort "usage: ruby fwsm.rb config" if ARGV.size < 1

CONFIG=ARGV[0]



puts "config: '%s'" % [CONFIG]
config = YAML::load(File.open(CONFIG))
managers = {}
aggregators = {}

config[:config_managers].each do |device_name,options|
	options[:user_map] = config[:user_maps][options[:user_map]] if options[:user_map] 
	managers[device_name] = FWSMConfigManager.new(
		config[:devices][device_name][:host],
		config[:devices][device_name][:user],
		config[:devices][device_name][:pass],
		options
	)
	aggregators[device_name] = FWSMChangeAggregator.new(managers[device_name])
end

syslog = SyslogListener.new(config[:syslog][:address],config[:syslog][:port], aggregators, config[:device_maps])

syslog.run
