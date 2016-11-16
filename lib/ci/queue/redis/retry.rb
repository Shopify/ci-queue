module CI
  module Queue
    module Redis
      class Retry < Static
        def initialize(tests, redis:, build_id:, worker_id:, **args)
          @redis = redis
          @build_id = build_id
          @worker_id = worker_id
          super(tests, **args)
        end

        def minitest_reporters
          require 'minitest/reporters/redis_reporter'
          @minitest_reporters ||= [
            Minitest::Reporters::RedisReporter::Worker.new(
              redis: redis,
              build_id: build_id,
              worker_id: worker_id,
            )
          ]
        end

        private

        attr_reader :redis, :build_id, :worker_id
      end
    end
  end
end
