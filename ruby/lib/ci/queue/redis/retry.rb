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

        # Queue a Redis SADD so that BuildRecord#record_success can include this
        # in its multi-exec transaction. Without this, Static#acknowledge returns
        # a Ruby value (not a Redis future), shifting the result indices and
        # breaking the stats delta correction.
        def acknowledge(entry, error: nil, pipeline: redis)
          @progress += 1
          return @progress unless pipeline
          test_id = CI::Queue::QueueEntry.test_id(entry)
          pipeline.sadd(key('processed'), test_id)
        end

        private

        attr_reader :redis

        def key(*args)
          ['build', config.build_id, *args].join(':')
        end
      end
    end
  end
end
