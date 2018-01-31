module CI
  module Queue
    module Redis
      class Retry < Static
        def initialize(tests, config, redis:)
          @redis = redis
          super(tests, config)
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def minitest_reporters
          require 'minitest/reporters/queue_reporter'
          require 'minitest/reporters/redis_reporter'
          @minitest_reporters ||= [
            Minitest::Reporters::QueueReporter.new,
            Minitest::Reporters::RedisReporter::Worker.new(build: build),
          ]
        end

        private

        attr_reader :redis
      end
    end
  end
end
