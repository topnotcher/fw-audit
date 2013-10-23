require_relative 'fwsm'

abort "usage: ruby fwsm.rb host user pass dir" if ARGV.size < 4

SSH_USER=ARGV[1]
SSH_PASS=ARGV[2]
SSH_HOST=ARGV[0]
REPO_DIR=ARGV[3]

#OUTPUT_DIR='/home/greg/iso/backup/cisco/fwsm'

fwsm = Fwsm.new(SSH_HOST,SSH_USER,SSH_PASS)
fwsm.run

