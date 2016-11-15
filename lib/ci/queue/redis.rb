require 'redis'
require 'ci/queue/redis/base'
require 'ci/queue/redis/worker'
require 'ci/queue/redis/supervisor'

module CI
  module Queue
    module Redis
      Error = Class.new(StandardError)
      LostMaster = Class.new(Error)

      def self.new(*args)
        Worker.new(*args)
      end
    end
  end
end
