require 'net/ssh'

class FwsmDumper

	def initialize(fwsm)
		@fwsm = fwsm
		@fwsm.connect
	end

	
	def get_context_config(context)
		result = @fwsm.cmd 'changeto context %s' % [context]

		# handles contexts that do not exist
		raise "Failed to change to %s: %s" % [context,result] if result =~ /^ERROR:/

		return @fwsm.cmd 'show run'
	end

	def get_contexts
		contexts = []

		@fwsm.cmd 'changeto system'
		data = @fwsm.cmd 'show context'

		data.each_line do |line|
			next unless line.start_with? '*',' '
			contexts << line[1..line.index(' ',1)-1]
		end 

		return contexts
	end

	def exit
		@fwsm.cmd 'exit'
	end
end

class Fwsm

	@@prompt = /> $/
	@@enprompt = /# $/
	@@pwprompt = /^Password:/	
	@@crlf = "\r\n"

	def initialize(host,user,pass)
		@pass = pass
		@user = user
		@host = host

		@mutex = Mutex.new
		@cv = ConditionVariable.new
	end

	def connect
		@state = :new
		@ignore_echo_chars = 0
		@pwtries = 0
		@buf = ''
		@last_cmd = nil

		@ssh = Net::SSH.start(@host ,@user, {:password => @pass, :auth_methods => ['password']})

		@ssh.open_channel do |chan|
			chan.send_channel_request('shell') do |ch,success|
				raise 'Failed to open shell channel!' unless success
				@channel = ch
				ch.on_data {|chn,data| handle_data(chn,data)}
			end
		end 

		run


		cmd 'terminal pager 0'
	end

	def cmd(cmd) 
		@buf = ''

		# echoed commands always echo back with CRLF even if I send LF
		@last_cmd = cmd + @@crlf
		@ignore_echo_chars = @last_cmd.length 

		@mutex.synchronize {
			@cv.signal
			@cv.wait(@mutex,30)
		}

		return @buf.strip
	end

	def run
		@mutex.synchronize {
			Thread.new { @ssh.loop }
			@cv.wait(@mutex,30)
		}
	end
	
	def handle_data(chn, data)
		if @state == :new and data =~ @@prompt
			@state = :normal
			chn.send_data("enable\n")

		elsif @state == :normal and data =~ @@pwprompt
			if (@pwtries += 1) < 4
				chn.send_data(@pass + "\n")
			else
				raise 'Too many pw tries!'
			end
		
		elsif data =~ @@enprompt
			if @state != :enabled
				@state = :enabled
			end
		
			@mutex.synchronize {
				@cv.signal 
				@cv.wait(@mutex)

				@channel.send_data(@last_cmd) unless @last_cmd.nil?
				@last_cmd = nil
			}

		elsif @state == :enabled
			# filter echoed commands 
			if data.length == 1 and @ignore_echo_chars > 0
				@ignore_echo_chars -= 1
			else 
				@buf += data
			end	
		end
	end

	def close
		10.times { chn.send_data("exit\n") unless (!chn.active? || chn.closing?) }
	end
end
