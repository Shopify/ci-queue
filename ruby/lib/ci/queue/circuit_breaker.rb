# frozen_string_literal: true
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

        def message
          ''
        end
      end

      class Timeout
        attr_reader :duration, :opened_at, :closes_at

        def initialize(duration:)
          @duration = duration
          @opened_at = current_timestamp
          @closes_at = @opened_at + duration
        end

        def report_failure!
        end

        def report_success!
        end

        def open?
          closes_at < current_timestamp
        end

        def message
          "This worker is exiting early because it reached its timeout of #{duration} seconds"
        end

        private

        def current_timestamp
          Time.now.to_i
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

      def message
        'This worker is exiting early because it encountered too many consecutive test failures, probably because of some corrupted state.'
      end
    end
  end
end
