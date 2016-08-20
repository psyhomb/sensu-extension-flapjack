# Sends events to Flapjack for notification routing. See http://flapjack.io/
#
# This extension requires Flapjack >= 0.8.7 and Sensu >= 0.13.1
#
# In order for Flapjack to keep its entities up to date, it is necssary to set
# metric to "true" for each check that is using the flapjack handler extension.
#
# Here is an example of what the Sensu configuration for flapjack should
# look like, assuming your Flapjack's redis service is running on the
# same machine as the Sensu server:
#
# Flapjack v1.6:
#
# {
#   "flapjack": {
#      "host": "localhost",
#      "port": 6379,
#      "db": "0",
#      "initial_failure_delay": 30,
#      "repeat_failure_delay": 60,
#      "flapjack_version": 1,
#      "enabled": true
#   }
# }
#
# Flapjack v2:
#
# {
#   "flapjack": {
#      "host": "localhost",
#      "port": 6379,
#      "db": "0",
#      "initial_failure_delay": 30,
#      "repeat_failure_delay": 60,
#      "flapjack_version": 2,
#      "enabled": true
#   }
# }
#
# Starting from version 0.23 Sensu services can now be configured to query one or more instances of Redis Sentinel for a Redis master,
# and cause we're requiring the same 'sensu/redis' gem for Flapjack extension, we can use this feature here as well.
# More info here:
#   https://sensuapp.org/docs/latest/reference/redis.html#configuring-sensu-for-redis-sentinel
#   https://github.com/sensu/sensu/blob/master/CHANGELOG.md
#
# {
#   "flapjack": {
#     "master": "mymaster",
#     "db": 0,
#     "auto_reconnect": true,
#     "sentinels": [
#       {
#         "host": "1.1.1.1",
#         "port": 26379
#       },
#       {
#         "host": "1.1.1.2",
#         "port": 26379
#       },
#       {
#         "host": "1.1.1.3",
#         "port": 26379
#       }
#     ],
#     "initial_failure_delay": 30,
#     "repeat_failure_delay": 60,
#     "flapjack_version": 1,
#     "enabled": true
#   }
# }
#
# How to configure some of the Flapjack attributes on the check level (check level has precedence over global configuration):
#
# {
#   "checks": {
#     "check_disk_usage": {
#       "command": "check-disk-usage.rb",
#       "subscribers": [
#         "test"
#       ],
#       "interval": 60,
#       "output_type": "nagios",
#       "initial_failure_delay": 300,
#       "repeat_failure_delay": 300,
#       "flapjack_enabled": false
#     }
#   }
# }
#
# Copyright 2014 Jive Software and contributors.
#
# Released under the same terms as Sensu (the MIT license); see LICENSE for details.

require 'sensu/redis'

module Sensu
  module Extension
    class Flapjack < Bridge
      def name
        'flapjack'
      end

      def description
        'sends sensu events to the flapjack redis queue'
      end

      def options
        return @options if @options
        @options = {
          host: '127.0.0.1',
          port: 6379,
          channel: 'events',
          db: 0,
          initial_failure_delay: 30,
          repeat_failure_delay: 60,
          flapjack_version: 1,
          enabled: true
        }
        if @settings[:flapjack].is_a?(Hash)
          @options.merge!(@settings[:flapjack])
        end
        @options
      end

      def definition
        {
          type: 'extension',
          name: name,
          mutator: 'ruby_hash'
        }
      end

      def post_init
        Redis.connect(options) do |connection|
          @redis = connection
          @redis.on_error do |_error|
            @logger.warn('Flapjack Redis instance not available on ' + options[:host])
          end
          # @redis.before_reconnect do
          #   @logger.warn("reconnecting to redis")
          #   pause
          # end
          # @redis.after_reconnect do
          #   @logger.info("reconnected to redis")
          #   resume
          # end
          yield(@redis) if block_given?
        end
      end

      def run(event)
        client = event[:client]
        check = event[:check]

        initial_failure_delay = @options[:initial_failure_delay]
        repeat_failure_delay = @options[:repeat_failure_delay]
        flapjack_version = @options[:flapjack_version]
        enabled = @options[:enabled]

        check_enabled = if [true, false].include? check[:flapjack_enabled]
                          check[:flapjack_enabled]
                        else
                          true
                        end

        if not enabled
          yield 'flapjack extension has been globally DISABLED', 0
          return
        elsif not check_enabled
          yield 'flapjack extension has been DISABLED for check #{client[:name]}:#{check[:name]}', 0
          return
        end

        # Handle nagios output format with perfdata: TEXT | PERFDATA
        if check[:output_type].eql? 'nagios'
          if check[:output].include? '|'
            nagios_full_output = check[:output].split('|')
            nagios_text_output = nagios_full_output.first.strip
            nagios_perfdata_output = nagios_full_output[1..nagios_full_output.length].join('|').strip

            check[:output] = nagios_text_output
            check[:perfdata] = nagios_perfdata_output if flapjack_version.eql? 1
          end
        end

        tags = []
        tags.concat(client[:tags]) if client[:tags].is_a?(Array)
        tags.concat(check[:tags]) if check[:tags].is_a?(Array)
        tags << client[:environment] unless client[:environment].nil?
        # #YELLOW
        unless check[:subscribers].nil? || check[:subscribers].empty? # rubocop:disable UnlessElse
          tags.concat(client[:subscriptions] - (client[:subscriptions] - check[:subscribers]))
        else
          tags.concat(client[:subscriptions])
        end
        tags.concat(client[:roles].split).uniq! unless client[:roles].nil?
        details = ['Address:' + client[:address]]
        details << 'Tags:' + tags.join(',')
        details << "Raw Output: #{check[:output]}" if check[:notification]

        flapjack_event = {
          entity: client[:name],
          check: check[:name],
          type: 'service',
          state: Sensu::SEVERITIES[check[:status]] || 'unknown',
          summary: check[:notification] || check[:output],
          details: details.join(' '),
          time: check[:executed],
          tags: tags
        }

        flapjack_event[:perfdata] = check[:perfdata] if check[:perfdata]
        flapjack_event[:initial_failure_delay] = initial_failure_delay
        flapjack_event[:repeat_failure_delay] = repeat_failure_delay
        flapjack_event[:initial_failure_delay] = check[:initial_failure_delay] if check[:initial_failure_delay]
        flapjack_event[:repeat_failure_delay] = check[:repeat_failure_delay] if check[:repeat_failure_delay]

        @redis.lpush(options[:channel], Sensu::JSON.dump(flapjack_event))
        @redis.lpush('events_actions', '+') if flapjack_version.eql? 2
        yield 'sent an event to the flapjack redis queue', 0
      end
    end
  end
end
