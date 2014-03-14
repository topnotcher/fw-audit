require_relative 'fwsm'

class FWSMChangeSet
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

class FWSMChangeAggregator
	# commit automatically after 30 seconds with no additional changes
	# and no write memory
	@@commit_timeout = 30

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

	def fwsm_event_111008(context, dt, msg)
		pcs = msg.scan(/^User '([^']+)' executed the '([^']+)' command\.$/)
		raise 'unable to parse log %s' % [msg] if pcs.length != 1 or pcs[0].length != 2
		user,cmd = pcs[0]

		# this is automatic everytime anyone does anything
		# @TODO configurable
		return if user == 'failover' or user == 'isobackup'
		
		# @TODO configurable
		return if cmd.start_with?('changeto context') or cmd.start_with?('perfmon interval') or cmd.start_with?('copy')

		@changes[context] = FWSMChangeSet.new(context,user) if @changes[context].nil?

		@changes[context] <<  "%s[%s](%s): %s" % [dt,context,user,cmd]

		if cmd == 'write memory'
			# note: could commit for JUST a write mem. cryptochecksum will change
			commit(context)
		end

	end

	def commit(context)
		@manager.commit(@changes[context])
		@changes[context] = nil
	end
end

FWSMPendingCommit = Struct.new(:user, :message)

class FWSMConfigManager
	@@config_check_timeout = 3600
	@@sleep_time = 30

	def initialize(host, user, pass, user_map, repo_dir)
		@host = host
		@user = user
		@pass = pass
		@user_map = user_map
		@repo_dir = repo_dir
		@mutex = Mutex.new
		@cv = ConditionVariable.new

		@contexts = {}
		@pending_commits = {}

		thr = Thread.new { start }
		thr.abort_on_exception = true
	end

	def start
	
		# a bit ugly:
		# make sure we update everything on start
		fwsm_connect
		# they're ALL stale right now
		check_config_freshness
		pending = get_pending_commits
		do_pending_commits(pending) if pending != 0
		fwsm_exit

		while true
			@mutex.synchronize {
				@cv.wait(@mutex,@@sleep_time)
			}

			check_config_freshness
			pending = get_pending_commits

			next if pending.size == 0
			
			fwsm_connect
			do_pending_commits(pending)
			fwsm_exit
		end
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

	def map_fwsm_user(user)
		if @user_map.has_key? user
			return @user_map[user]
		else
			return '%s <%s@%s>' % [user,user,@user_map[:default_suffix]]
		end
	end

	def schedule_stale_commit(context)
		user = map_fwsm_user('backup')	
		commit = FWSMPendingCommit.new(user, "Autocommit due to timeout (this may be a bug)")
		@pending_commits[context] = commit

		puts "%s is stale; scheduling backup" % [context]
	end

	def populate_contexts
		@fwsm.get_contexts.each do |context|
			@contexts[context] = 0 unless @contexts.has_key? context
		end
	end

	def fwsm_exit
		@fwsm.exit
		@fwsm = nil
	end

	def fwsm_connect
		@fwsm = FwsmDumper.new(Fwsm.new(@host,@user,@pass))
		populate_contexts
	end

	def commit(changes)
		msg = "Changes to %s by %s\n\n" % [changes.context, changes.user]
		changes.msgs.each do |cmd|
			 msg += cmd + "\n"
		end

		context = changes.context
		user = map_fwsm_user(changes.user)
		pending = FWSMPendingCommit.new(user, msg)

		@mutex.synchronize {
			# it's possible there's a scheduled staleness
			# commit here and we'll actually drop this changeset
			# and do an autocommit as backup user instead, but hopefully
			# this is a pretty damn small edge case.
		
			@pending_commits[context] = pending unless @pending_commits.has_key? context

			@cv.signal
		}
	end

	def do_pending_commits(pending)
		pending.each do |context,commit|
			config = @fwsm.get_context_config(context)
			write_fw_config(context,config)
			@contexts[context] = Time.now.to_i

			puts "--------------------------------------------------------"
			puts commit.message

			git_commit(commit.message, commit.user)
		end
		# should not reach this point unless there were pending...
		git_push
	end

	def git_commit(msg, author)
		gitargs = '--git-dir='+@repo_dir+'/.git' + ' --work-tree='+@repo_dir
 		tags = `git #{gitargs} diff HEAD -G '[A-Z]+\-[0-9]+' -U0`.scan(/[A-Z]+\-[0-9]+/).uniq.join(', ')
		`git #{gitargs} commit -m "#{tags} #{msg}" --author="#{author}"`
	end

	def git_push
		gitargs = '--git-dir='+@repo_dir+'/.git' + ' --work-tree='+@repo_dir
		`git #{gitargs} push stash testing`
	end

	def write_fw_config(context,config)
		bkfile = @repo_dir+'/'+context
		cnf = File.open(@repo_dir+'/'+context,'w')
		cnf << config.gsub!("\r","")
		cnf.close
		
		gitargs = '--git-dir='+@repo_dir+'/.git' + ' --work-tree='+@repo_dir
		`git #{gitargs} add #{bkfile}`
	end
end
