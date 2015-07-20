require_relative 'syslog'
require_relative 'committer'
require 'yaml'

abort "usage: ruby run.rb config" if ARGV.size < 1

CONFIG=ARGV[0]

config = YAML::load(File.open(CONFIG))

Process.daemon()

managers = {}
aggregators = {}

if config[:logfile]
	logger = Logger.new(config[:logfile])
end

config[:config_managers].each do |device_name,options|
	options[:user_map] = config[:user_maps][options[:user_map]] if options[:user_map]
	if logger
		options[:logger] = logger
	end

	managers[device_name] = CiscoFWConfigManager.new(
		config[:devices][device_name][:host],
		config[:devices][device_name][:user],
		config[:devices][device_name][:pass],
		options
	)
	aggregators[device_name] = CiscoFWChangeAggregator.new(managers[device_name])
end

syslog = SyslogListener.new(config[:syslog][:address],config[:syslog][:port], aggregators, config[:device_maps])


if config[:pidfile]
	File.open(config[:pidfile], 'w') {|pidfile| pidfile.write(Process.pid)}
end

syslog.run
