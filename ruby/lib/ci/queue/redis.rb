# frozen_string_literal: true

gem "redis", "~> 5.0"
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
      LostMaster = Class.new(CI::Queue::Error)
      ReservationError = Class.new(CI::Queue::Error)

      class << self

        def new(*args)
          Worker.new(*args)
        end

        def from_uri(uri, config)
          new(uri.to_s, config)
        end
      end
    end
  end
end
