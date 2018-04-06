module CI
  module Queue
    class CircuitBreaker
      module Disabled
        extend self

        def report_failure!
        end

        def report_success!
        end

        def open?
          false
        end
      end

      def initialize(max_consecutive_failures:)
        @max = max_consecutive_failures
        @consecutive_failures = 0
      end

      def report_failure!
        @consecutive_failures += 1
      end

      def report_success!
        @consecutive_failures = 0
      end

      def open?
        @consecutive_failures >= @max
      end
    end
  end
end
