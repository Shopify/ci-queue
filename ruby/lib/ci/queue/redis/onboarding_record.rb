module CI
  module Queue
    module Redis
      class OnboardingRecord
        def initialize(queue, redis)
          @queue = queue
          @redis = redis
          # @config = config
        end

        def record_error(id, context)
          redis.pipelined do
            redis.hset(
              key('onboarding'),
              ENV['BUILDKITE_JOB_ID'],
              id.force_encoding(Encoding::BINARY),
              payload.force_encoding(Encoding::BINARY),
            )
          end
        end

        def get_errors
          # get errors from redis
        end

        private

        attr_reader :queue, :redis, :config
      end
    end
  end
end
