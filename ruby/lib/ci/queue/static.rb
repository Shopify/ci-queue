module CI
  module Queue
    class Static
      attr_reader :progress, :total

      def initialize(tests, max_requeues: 0, requeue_tolerance: 0.0)
        @queue = tests
        @progress = 0
        @total = tests.size
        @max_requeues = max_requeues
        @global_max_requeues = (tests.size * requeue_tolerance).ceil
      end

      def to_a
        @queue.dup
      end

      def size
        @queue.size
      end

      def poll
        while test = @queue.shift
          yield test
          @progress += 1
        end
      end

      def empty?
        @queue.empty?
      end

      def acknowledge(test)
        true
      end

      def requeue(test)
        return false unless should_requeue?(test)
        requeues[test] += 1
        @queue.unshift(test)
        true
      end

      private

      attr_reader :max_requeues, :global_max_requeues

      def should_requeue?(test)
        requeues[test] < max_requeues && requeues.values.inject(0, :+) < global_max_requeues
      end

      def requeues
        @requeues ||= Hash.new(0)
      end
    end
  end
end
