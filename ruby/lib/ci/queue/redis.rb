# frozen_string_literal: true

require 'redis'
require 'ci/queue/redis/build_record'
require 'ci/queue/redis/base'
require 'ci/queue/redis/worker'
require 'ci/queue/redis/grind_record'
require 'ci/queue/redis/grind'
require 'ci/queue/redis/retry'
require 'ci/queue/redis/supervisor'
require 'ci/queue/redis/grind_supervisor'
require 'ci/queue/redis/test_time_record'

module CI
  module Queue
    module Redis
      Error = Class.new(StandardError)
      LostMaster = Class.new(Error)

      class << self

        def new(*args)
          Worker.new(*args)
        end

        def from_uri(uri, config)
          redis = if ::Redis::VERSION > "5.0.0"
            ::Redis.new(
              url: uri.to_s,
              # # Booting a CI worker is costly, so in case of a Redis blip,
              # # it makes sense to retry for a while before giving up.
              # reconnect_attempts: reconnect_attempts,
              # middlewares: custom_middlewares,
              # custom: custom_config,
            )
          else
            ::Redis.new(url: uri.to_s)
          end

          new(redis, uri.to_s, config)
        end
      end
    end
  end
end
