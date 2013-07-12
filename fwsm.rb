require 'net/ssh'


abort "usage: ruby fwsm.rb host user pass" if ARGV.size < 3

SSH_USER=ARGV[1]
SSH_PASS=ARGV[2]
SSH_HOST=ARGV[0]

#config_file = File.open('fwsm.conf','w')
#outbuf = ''
#last_cmd = ''

class Fwsm

	@@prompt = /> $/
	@@enprompt = /# $/
	@@pwprompt = /^Password:/	
	@@crlf = "\r\n"

	def initialize(host,user,pass)
		@pass = pass
		@cmds = ['terminal pager 0', 'changeto system', 'show context', 'changeto context OIS-Webservers','show run']
		@ssh = Net::SSH.start(host ,user, {:password => pass, :auth_methods => ['password']})
		@state = 'new'
		@ignore_echo_chars = 0
		@pwtries = 0
		@buf = ''
		@last_cmd = nil

		@ssh.open_channel do |chan|
			chan.send_channel_request('shell') do |ch,success|
				raise 'Failed to open shell channel!' unless success
				ch.on_data {|chn,data| handle_data(chn,data)}
			end
		end  
	end

	def run
		@ssh.loop
	end

	def handle_data(chn, data)

		if @state == 'new' and data =~ @@prompt
			@state = 'normal'
			chn.send_data("enable\n")

		elsif @state == 'normal' and data =~ @@pwprompt
			if (@pwtries += 1) < 4
				chn.send_data(@pass + "\n")
			else
				raise 'Too many pw tries!'
			end
		
		elsif data =~ @@enprompt
			@state = 'enabled'
			puts @buf if @last_cmd
			unless @cmds.size == 0
				@buf = ''
				@last_cmd = @cmds.shift + @@crlf
				@ignore_echo_chars = @last_cmd.length 
				chn.send_data(@last_cmd)
			else 
				10.times { chn.send_data("exit\n") unless (!chn.active? || chn.closing?)}
			end	

		elsif @state == 'enabled'
			if data.length == 1 and @ignore_echo_chars > 0
				@ignore_echo_chars -= 1
			else 
				@buf += data
			end	
		end
	end
end


fwsm = Fwsm.new(SSH_HOST,SSH_USER,SSH_PASS)
fwsm.run

