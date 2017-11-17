module CI
  module Queue
    module Redis
      class Retry < Static
        def initialize(tests, config, redis:)
          @redis = redis
          super(tests, config)
        end

        def minitest_reporters
          require 'minitest/reporters/redis_reporter'
          @minitest_reporters ||= [
            Minitest::Reporters::RedisReporter::Worker.new(
              redis: redis,
              build_id: config.build_id,
              worker_id: config.worker_id,
            )
          ]
        end

        private

        attr_reader :redis
      end
    end
  end
end
