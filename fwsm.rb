require 'net/ssh'


abort "usage: ruby fwsm.rb host user pass" if ARGV.size < 3

SSH_USER=ARGV[1]
SSH_PASS=ARGV[2]
SSH_HOST=ARGV[0]

#config_file = File.open('fwsm.conf','w')
#outbuf = ''
#last_cmd = ''


class FwsmDumper

	@@show_context = 'show context'
	@@changeto_system = 'changeto system'

	@@changeto_context = 'changeto context '

	@@show_run = 'show run'


	def initialize(fwsm)
		@fwsm = fwsm
		@state = 'init'

		@contexts = nil
		@context = 'admin'
	end


	def ready(prompt)
		if @state == 'init'
			@state = 'show contexts' 
			@fwsm.cmd(@@changeto_system)
			@fwsm.cmd(@@show_context)
		elsif @state == 'dump' and @contexts.size > 0
			@context = @contexts.shift
			@fwsm.cmd(@@changeto_context + @context)
			@fwsm.cmd(@@show_run)
		end 

	end

	def cmd_result(cmd, data)
		if cmd == @@show_context and not @contexts
			populate_contexts(data)
			@state = 'dump'
		elsif cmd == @@show_run and @state == 'dump'
			cnf = File.open(@context,'w')
			cnf << data
			cnf.close
		end
	end


	def populate_contexts(data)
		@contexts = []
		
		data.each_line do |line|
			next unless line.start_with? '*',' '
			@contexts << line[1..line.index(' ',1)-1]
		end 

		puts @contexts
	end			
	
end

class Fwsm

	@@prompt = /> $/
	@@enprompt = /# $/
	@@pwprompt = /^Password:/	
	@@crlf = "\r\n"

	def initialize(host,user,pass)
		@pass = pass
		@cmds = ['terminal pager 0']
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

	def cmd(cmd) 
		@cmds << cmd 
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
			if @state != 'enabled'
				@state = 'enabled'
				@dumper = FwsmDumper.new(self)
			end

			
			@dumper.cmd_result(@last_cmd.strip, @buf) if @last_cmd
			@dumper.ready(data)
	
			unless @cmds.size == 0
				@buf = ''

				# echoed commands always echo back with CRLF even if I send LF
				@last_cmd = @cmds.shift + @@crlf
				@ignore_echo_chars = @last_cmd.length 

				chn.send_data(@last_cmd)
			else 
				10.times { chn.send_data("exit\n") unless (!chn.active? || chn.closing?)}
			end	

		elsif @state == 'enabled'
			# filter echoed commands 
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

