require 'json'
require 'celluloid/eventsource'
require 'xmlrpc/client'
require 'yaml'
require 'syslog/logger'

log = Syslog::Logger.new 'Hystrix-zenoss-notifier'
cnf = YAML::load_file(File.join(__dir__, 'config.yml'))

def zenoss_report(info, cnf)
  uri = URI(cnf['zenoss-server'])
  payload = { action: 'EventsRouter',
                method: 'add_event',
                data: [
                        { summary: info[:summary],
                          device: info[:device],
                          component: info[:component],
                          severity: info[:severity],
                          evclasskey: '',
                          evclass: '/APP'
                        }
                      ],
                type: 'rpc',
                tid: '1'
            }

  request = Net::HTTP::Post.new(uri.path)
  request.basic_auth cnf['zenoss-user'], cnf['zenoss-password']
  request.content_type = 'application/json'
  request.body = payload.to_json

  http = Net::HTTP.new( uri.host, uri.port )
  http.request( request )
end

Celluloid::EventSource.new(cnf['hystrix-server']) do |conn|
  conn.on_open do
    log.info "Connection to hystrix server was made"
    log.info "Blacklisted circuits: #{cnf['blacklist'].join('   ')}"
  end

  conn.on_message do |event|
    begin
      data = JSON.parse event.data
      unless cnf['blacklist'].include? data['name']
        if data['propertyValue_circuitBreakerForceOpen']
          zenoss_report({summary: "The circuit breaker for #{data['name'] rescue "Unknown Breaker"} is forced open", device: data['name'], component: cnf['components'][:one], severity: "Critical"}, cnf)
          log.error "The circuit breaker for #{data['name'] rescue "Unknown Breaker"} (#{cnf['components'][:one]}) is forced open"
        end
        if data['isCircuitBreakerOpen']
          zenoss_report({summary: "The circuit breaker for #{data['name'] rescue "Unknown Breaker"} is short circuited", device: data['name'], component: cnf['components'][:one], severity: "Critical"}, cnf)
          log.error "The circuit breaker for #{data['name'] rescue "Unknown Breaker"} (#{cnf['components'][:one]}) is short circuited"
        end
        if data && data['errorCount'] && data['errorCount'] > 0
          zenoss_report({summary: "There are errors on #{data['name'] rescue "Unknown Breaker"}", device: data['name'], component: cnf['components'][:one], severity: "Error"}, cnf)
          log.warn "There are errors on #{data['name'] rescue "Unknown Breaker"} (#{cnf['components'][:one]})"
        end
      end
    rescue => e
      log.error "ERROR GETTING EVENT DATA: #{e} - #{event.data}\n\n"
    end
  end

  conn.on_error do |message|
    log.error "Response status #{message[:status_code]}, Response body #{message[:body]}"
  end

  conn.on(:time) do |event|
    log.info "The time is #{event.data}"
  end
end

loop do
  sleep 15
end
