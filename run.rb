require_relative 'fwsm'
require_relative 'syslog'
require_relative 'commiter'
require 'yaml'

abort "usage: ruby fwsm.rb host user pass dir" if ARGV.size < 4

SSH_USER=ARGV[1]
SSH_PASS=ARGV[2]
SSH_HOST=ARGV[0]
REPO_DIR=ARGV[3]

config = YAML::load(File.open('config.yml'))

manager = FWSMConfigManager.new(SSH_HOST, SSH_USER, SSH_PASS, config[:user_map], REPO_DIR)
syslog = FWSMChangePublisher.new(config[:address],config[:port], config[:context_map])
syslog.subscribe(FWSMChangeAggregator.new(manager))


syslog.run
