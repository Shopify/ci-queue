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

        # Retry queue is pre-populated with failed test entries from the previous run.
        # Don't replace them with the full preresolved/lazy test list.
        # QueuePopulationStrategy#configure_lazy_queue will still set entry_resolver,
        # so poll uses LazyEntryResolver to lazily load test files on demand.
        # The random/batch_size params are intentionally ignored since we keep
        # the existing queue contents as-is.
        #
        # Note: populate (non-stream) is intentionally NOT overridden here.
        # RSpec and non-lazy Minitest retries call populate to build the
        # @index mapping test IDs to runnable objects, which poll needs to
        # yield proper test/example instances. In those paths, @queue contains
        # bare test IDs that match @index keys, so populate works correctly.
        def stream_populate(tests, random: nil, batch_size: nil)
          self
        end

        private

        attr_reader :redis
      end
    end
  end
end
