# frozen_string_literal: true
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

        private

        attr_reader :redis
      end
    end
  end
end
