require 'socket'
require 'time'

class SyslogListener
	@@max = 512

	# map = { 'ContextName' => [ip1,ip2] }
	def initialize(ip,port,aggregators,device_maps)
		@sock = UDPSocket.new
		@sock.bind(ip,port)
		@listeners = aggregators
		load_map(device_maps)
	end
	
	def load_map(map)
		@map = {}
		map.each do |device,ips|
			ips.each {|ip| @map[ip] = device}
		end
		puts @map
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

		notify(host,context,dt,event,msg)
	end

	def parse_log(msg)
		pcs = msg.scan(/^<[0-9]+>(.{15}) ([0-9\.]+) (?:([A-Za-z0-9\-_]+) )?%(?:FWSM|ASA)-[0-9]-([0-9]+): (.*)$/)
		raise 'unable to parse log %s' % [msg] if pcs.length != 1 or pcs[0].length != 5 

		data = pcs[0]

		# dt, host, context, event, msg
		return Time.parse(data[0]),data[1],data[2],data[3],data[4]
	end

	# name of context if ip in map, else nil
	def lookup_device(ip)
		@map[ip]
	end

	def notify(host,context,dt,event,msg)
		method = 'fwsm_event_' + event
		device = lookup_device(host)
		raise "Unable to map IP %s to device" % [host] if device.nil?
		listener = @listeners[device]	

		return unless listener.respond_to? method
		begin 
			listener.send method, context, dt, msg
		rescue
			puts $!, $@ #@TODO
		end
	end

end
