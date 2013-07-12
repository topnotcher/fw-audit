require 'net/ssh'


abort "usage: ruby fwsm.rb host user pass" if ARGV.size < 3

SSH_USER=ARGV[1]
SSH_PASS=ARGV[2]
SSH_HOST=ARGV[0]

config_file = File.open('fwsm.conf','w')
outbuf = ''
last_cmd = ''

ssh = Net::SSH.start(SSH_HOST ,SSH_USER, {:password => SSH_PASS, :auth_methods => ['password']})

pass_cnt = 0

cmds = ['terminal pager 0', 'show run']

ssh.open_channel do |chan|
	chan.send_channel_request('shell') do |ch, success|
		abort 'Failed to open shell channel!' unless success

		ch.on_data do |chn, data|

			outbuf += data

			outbuf = '' if outbuf == last_cmd or outbuf =~ /^[\r\n]+$/
	
			# normal prompt - send enable 
			chn.send_data("en\n") if data =~ /> $/

			# should pick up any password prompt (particularly aftersending enable)
			if data =~ /^Password:/
				abort 'Too many password attempts!' unless (pass_cnt += 1) <= 3
				chn.send_data(SSH_PASS + "\n")
			end

			# enable prompt: do show etcetc
			if data =~ /# $/

				config_file << outbuf if last_cmd != ''

				unless cmds.size == 0
					outbuf = ''
					last_cmd = cmds.shift
					chn.send_data(last_cmd + "\n") 
				else
					10.times do
						chn.send_data("exit\n") unless (!chn.active? || chn.closing?)
					end
				end	
			end # enable prompt 
		end
	end
end
ssh.loop
config_file.close
