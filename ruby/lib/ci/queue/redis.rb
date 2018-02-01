require 'redis'
require 'ci/queue/redis/build_record'
require 'ci/queue/redis/base'
require 'ci/queue/redis/worker'
require 'ci/queue/redis/retry'
require 'ci/queue/redis/supervisor'

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
          new(uri.to_s, config)
        end
      end
    end
  end
end
