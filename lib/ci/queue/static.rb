module CI
  module Queue
    class Static
      attr_reader :progress, :total

      def initialize(tests)
        @queue = tests
        @progress = 0
        @total = tests.size
      end

      def to_a
        @queue.dup
      end

      def size
        @queue.size
      end

      def poll
        while test = @queue.pop
          yield test
          @progress += 1
        end
      end

      def empty?
        @queue.empty?
      end
    end
  end
end
