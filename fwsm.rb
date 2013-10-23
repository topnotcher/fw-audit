require 'net/ssh'

class FwsmDumper

	@@show_context = 'show context'
	@@changeto_system = 'changeto system'

	@@changeto_context = 'changeto context '

	@@show_run = 'show run'


	def initialize(fwsm,repo_dir)
		@repo_dir = repo_dir
		@fwsm = fwsm
		@state = :init

		@contexts = nil
		@context = 'admin'
	end


	def ready(prompt)
		if @state == :init
			@state = :show_contexts
			@fwsm.cmd(@@changeto_system)
			@fwsm.cmd(@@show_context)
		elsif @state == :dump
			if @contexts.size > 0
				@context = @contexts.shift
				@fwsm.cmd(@@changeto_context + @context)
				@fwsm.cmd(@@show_run)
			else
				git_commit	
			end
		end 

	end

	def git_commit
		gitargs = '--git-dir='+@repo_dir+'/.git' + ' --work-tree='+@repo_dir
 		tags = `git #{gitargs} diff HEAD -G '[A-Z]+\-[0-9]+' -U0`.scan(/[A-Z]+\-[0-9]+/).uniq.join(', ')
		`git #{gitargs} commit -m "automatic backup #{tags}" --author="backup <security@uri.edu>"`
		`git #{gitargs} push origin master`
	end

	def cmd_result(cmd, data)
		if cmd == @@show_context and not @contexts
			populate_contexts(data)
			@state = :dump
		elsif cmd == @@show_run and @state == :dump
			write_fw_config(data)
		end
	end

	def write_fw_config(data)
		bkfile = @repo_dir+'/'+@context
		cnf = File.open(@repo_dir+'/'+@context,'w')
		cnf << data.gsub!("\r","")
		cnf.close
		
		gitargs = '--git-dir='+@repo_dir+'/.git' + ' --work-tree='+@repo_dir
		`git #{gitargs} add #{bkfile}`
	end

	def populate_contexts(data)
		@contexts = []
		
		data.each_line do |line|
			next unless line.start_with? '*',' '
			@contexts << line[1..line.index(' ',1)-1]
		end 
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

		connect
	end

	def connect
		@cmds = ['terminal pager 0']
		@ssh = Net::SSH.start(host ,user, {:password => pass, :auth_methods => ['password']})
		@state = :new
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
				@dumper = FwsmDumper.new(self,REPO_DIR)
			end

			
			@dumper.cmd_result(@last_cmd.strip, @buf.strip) if @last_cmd
			@dumper.ready(data) if @cmds.size == 0
	
			unless @cmds.size == 0
				@buf = ''

				# echoed commands always echo back with CRLF even if I send LF
				@last_cmd = @cmds.shift + @@crlf
				@ignore_echo_chars = @last_cmd.length 

				chn.send_data(@last_cmd)
			else 
				10.times { chn.send_data("exit\n") unless (!chn.active? || chn.closing?) }
			end	

		elsif @state == :enabled
			# filter echoed commands 
			if data.length == 1 and @ignore_echo_chars > 0
				@ignore_echo_chars -= 1
			else 
				@buf += data
			end	
		end
	end
end
