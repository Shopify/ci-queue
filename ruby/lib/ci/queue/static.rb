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

      def populate(tests, &indexer)
        @index = Index.new(tests, &indexer)
        self
      end

      def populated?
        !!defined?(@index)
      end

      def to_a
        @queue.map { |i| index.fetch(i) }
      end

      def size
        @queue.size
      end

      def poll
        while test = @queue.shift
          yield index.fetch(test)
          @progress += 1
        end
      end

      def exhausted?
        @queue.empty?
      end

      def acknowledge(test)
        true
      end

      def requeue(test)
        key = index.key(test)
        return false unless should_requeue?(key)
        requeues[key] += 1
        @queue.unshift(index.key(test))
        true
      end

      private

      attr_reader :max_requeues, :global_max_requeues, :index

      def should_requeue?(key)
        requeues[key] < max_requeues && requeues.values.inject(0, :+) < global_max_requeues
      end

      def requeues
        @requeues ||= Hash.new(0)
      end
    end
  end
end
