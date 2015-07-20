require_relative 'cisco'
require 'logger'

class CiscoFWChangeSet
	attr_reader :context, :user, :msgs

	def initialize(context,user)
		@context = context
		@user = user
		@ts = Time.now.to_i
		@msgs = []
	end

	def <<(msg)
		@msgs << msg
		@ts = Time.now.to_i
	end

	def age
		Time.now.to_i - @ts
	end
end

class CiscoFWChangeAggregator
	# commit automatically after @@commit_timeout seconds with no additional
	# changes and no write memory
	@@commit_timeout = 120

	def initialize(manager)
		@manager = manager	
		@changes = {}

		thr = Thread.new {
			while true do
				check_timeouts
				sleep @@commit_timeout
			end
		}

		thr.abort_on_exception = true
	end

	def check_timeouts
		@changes.each do |context,changes|
			next if changes.nil?
			next if changes.age < @@commit_timeout
			commit(context)
		end
	end

	def parse_event_111008(msg)
		pcs = msg.scan(/^User '([^']+)' executed the '([^']+)' command\.$/)
		raise 'unable to parse log %s' % [msg] if pcs.length != 1 or pcs[0].length != 2
		return pcs[0]
	end

	def syslog_event(host, dt, log)
		pcs = log.scan /^([A-Za-z0-9\-_]+) %(?:FWSM|ASA)-[0-9]-([0-9]+): (.*)$/

		# only listen for event 111008
		return if pcs.size != 1 or pcs[0][1] != '111008'

		context = pcs[0][0]

		user,cmd = parse_event_111008(pcs[0][2])

		return if ignored_user(user) or ignored_cmd(cmd)

		@changes[context] = CiscoFWChangeSet.new(context,user) if @changes[context].nil?

		@changes[context] <<  "%s[%s](%s): %s" % [dt,context,user,cmd]

		if cmd == 'write memory'
			# note: could commit for JUST a write mem. cryptochecksum will change
			commit(context)
		end
	end

	def ignored_user(user)
		# @TODO configurable
		ignored = ['failover', 'isobackup']
		ignored.each do |ignored_user|
			return true if user == ignored_user
		end
		return false
	end
	
	def ignored_cmd(cmd)
		# @TODO configurable
		ignored = ['changeto ', 'perfmon interval', 'copy ', 'show ', 'ping ', 'enable', 'configure ']
		ignored.each do |ignored_cmd|
			return true if cmd.start_with? ignored_cmd
		end
		return false
	end
	
	def commit(context)
		@manager.commit(@changes[context])
		@changes[context] = nil
	end
end

CiscoFWPendingCommit = Struct.new(:user, :message)

class CiscoFWConfigManager
	@@config_check_timeout = 7200
	@@sleep_time = 30

	def initialize(host, user, pass, config)
		@host = host
		@user = user
		@pass = pass
		@config = config

		@mutex = Mutex.new
		@cv = ConditionVariable.new

		@contexts = {}
		@pending_commits = {}

		@logger = Logger.new(STDOUT)

		thr = Thread.new { start }
	end

	def start
		begin 
			startup_config_check
		rescue
			@logger.fatal $!
			abort("Aborting due to exception.")
		end

		while true
			# Sleep until timeout expires or  until commit()
			# is called to schedule a pending commit.
			@mutex.synchronize {
				@cv.wait(@mutex,@@sleep_time)
			}

			check_config_freshness
			pending = get_pending_commits

			next if pending.size == 0
			begin	
				fw_connect
				do_pending_commits(pending)
				fw_exit
			rescue
				logging.error $!
			end
		end
	end

	# on startup, we need to connect and populate the list of
	# contexts at least one time.
	def startup_config_check
		fw_connect
		# they are ALL stale right now...
		check_config_freshness
		pending = get_pending_commits
		do_pending_commits(pending) if pending != 0
		fw_exit
	end

	def get_pending_commits
		pending = {}
		@mutex.synchronize {
			pending = @pending_commits
			@pending_commits = {}
		}

		return pending
	end

	def check_config_freshness
		# gather any contexts that have not been checked for changes in a while
		@contexts.each do |context, freshness|
			@mutex.synchronize {
				next if @pending_commits.has_key? context
				schedule_stale_commit(context) if Time.now.to_i - freshness > @@config_check_timeout
			}
		end
	end

	def map_fw_user(user)
		if @config[:user_map].has_key? user
			return @config[:user_map][user]
		else
			return '%s <%s@%s>' % [user,user,@config[:user_map][:default_suffix]]
		end
	end

	def schedule_stale_commit(context)
		user = map_fw_user('backup')	
		commit = CiscoFWPendingCommit.new(user, "Autocommit due to timeout (this may be a bug)")
		@pending_commits[context] = commit

		@logger.info "%s is stale; scheduling backup" % [context]
	end

	def populate_contexts
		@fw.get_contexts.each do |context|
			@contexts[context] = 0 unless @contexts.has_key? context
		end
	end

	def fw_exit
		begin
			@fw.exit
		rescue
			@logger.error $!
		end
		@fw = nil
	end

	def fw_connect
		@fw = CiscoFWDumper.new(CiscoFW.new(@host,@user,@pass))

		# populate everytime in case a new context exists
		populate_contexts
	end

	def commit(changes)

		msg = "Changes to %s by %s\n\n" % [changes.context, changes.user]
		changes.msgs.each do |cmd|
			 msg += cmd + "\n"
		end

		# I'm not sure what caused this, but I did receive some syslogs with invalid
		# context names at one point, and it caused a new file with a junk config.
		unless @contexts.has_key? changes.context
			@logger.error "Attempt to commit to invalid context %s" % [changes.context]
			@logger.error "If the context has just been created, ignore this error."
			@logger.error "The following changes are being dropped: " 
			@logger.error msg
		end

		context = changes.context
		user = map_fw_user(changes.user)
		pending = CiscoFWPendingCommit.new(user, msg)

		@mutex.synchronize {
			# If there is another commit pending (small edge case?)
			# Then we'll combine them, but take the username from this
			# commit in case the pending one is for staleness
			# (which should be practically impossible?
			if @pending_commits.has_key? context
				pending = merge_commits(pending,@pending_commits[context])
			end

			@pending_commits[context] = pending

			@cv.signal
		}
	end

	def merge_commits(newer,older)
		msg = newer.message + "\n----------------------------------------------\n"
		msg += older.message
		return CiscoFWPendingCommit.new(newer.user, msg)
	end

	def do_pending_commits(pending)
		# this MUST be called AFTER a successful fw_connect
		pending.each do |context,commit|
			begin 
				update_context_config(context)
			rescue
				@logger.error $!
				next
			end

			@logger.debug 'Committing changes...' 
			@logger.debug commit.message

			begin 
				git_commit(commit.message, commit.user)
			rescue
				@logger.error $!
			end
		end
	
		begin
			git_push
		rescue
			@logger.warn $!
		end
	end

	def update_context_config(context)
		# key should always exist by this point via fw_connect
		# but @TODO handle context deletion?
		# raise "invalid context %s" unless @contexts.has_key? context

		config = @fw.get_context_config(context)
		write_fw_config(context,config)
		@contexts[context] = Time.now.to_i
	end
	
	# @TODO suppress output from git command
	def git(cmd)
		git_args = '--git-dir='+@config[:repo][:path]+'/.git' + ' --work-tree='+@config[:repo][:path]
		`git #{git_args} #{cmd}`
	end

	def git_commit(msg, author)
		# this is being used with stash/jira integration. If the diff
		# contains a jira ticket (i.e. CR-12), the ticket gets referenced in
		# the commit message, which links the diff to jira and the ticket to stash
		if @config[:tags]
			tags = git("diff HEAD -G '[A-Z]+\-[0-9]+' -U0").scan(/[A-Z]+\-[0-9]+/).uniq.join(', ')
			msg = "%s %s" % [tags,msg]
		end

		git "commit -m '#{msg}' --author='#{author}'"
	end

	def git_push
		if @config[:repo][:push]
			git "push #{@config[:repo][:push]}"
		end
	end

	def write_fw_config(context,config)
		bkfile = @config[:repo][:path]+'/'+context
		cnf = File.open(@config[:repo][:path]+'/'+context,'w')

		config.each_line do |line|
			cnf << line.gsub("\r",'') unless line.start_with? 'Cryptochecksum:'
		end

		cnf.close
		
		git "add #{bkfile}"
	end
end
