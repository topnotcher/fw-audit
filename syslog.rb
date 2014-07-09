require 'socket'
require 'time'

class FWSMChangePublisher
	@@max = 512

	# map = { 'ContextName' => [ip1,ip2] }
	def initialize(ip,port,map)
		@sock = UDPSocket.new
		@sock.bind(ip,port)
		@listeners = []
		load_map(map)
	end

	# Takes a context => [ips] map and converts it to ip => context
	def load_map(map)
		@map = {}
		map.each do |context,ips|
			ips.each {|ip| @map[ip] = context}
		end
	end

	def run
		while true do
			begin 
				process_log @sock.recvfrom(@@max)
			rescue
				# @TODO
				puts $!, $@
			end
		end
	end

	def process_log(data)
		dt,host,context,event,msg = parse_log(data[0])
	
		# Always use the mapped context if one has been provided.
		mapped_context = lookup_context(host)
		context = mapped_context unless context.nil?

		if context.nil?
			raise "Unable to map ip %s to context" % [host] if context.nil?
		end

		notify(context,dt,event,msg)
	end

	def parse_log(msg)
		pcs = msg.scan(/^<[0-9]+>(.{15}) ([0-9\.]+) (?:([A-Za-z0-9\-_]+) )?%(FWSM|ASA)-[0-9]-([0-9]+): (.*)$/)
		raise 'unable to parse log %s' % [msg] if pcs.length != 1 or pcs[0].length != 5 

		data = pcs[0]

		# dt, host, context, event, msg
		return Time.parse(data[0]),data[1],data[2],data[3],data[4]
	end

	# name of context if ip in map, else nil
	def lookup_context(ip)
		@map[ip]
	end

	def notify(context,dt,event,msg)
		method = 'fwsm_event_' + event
		@listeners.each do |listener|
			next unless listener.respond_to? method
			begin 
				listener.send method, context, dt, msg
			rescue
				puts $!, $@ #@TODO
			end
		end
	end

	def subscribe(me)
		@listeners << me
	end
end
