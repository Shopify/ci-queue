# frozen_string_literal: true
require 'test_helper'

module CI::Queue
  class CircuitBreakerTest < Minitest::Test
    def test_max_consecutive_requeues_starts_closed
      refute max_consecutive_requeues.open?
    end

    def test_max_consecutive_requeues_opens_at_threshold
      breaker = max_consecutive_requeues(max: 3)

      2.times { breaker.report_requeue! }
      refute breaker.open?

      breaker.report_requeue!
      assert breaker.open?
    end

    def test_success_resets_consecutive_requeues
      breaker = max_consecutive_requeues(max: 3)

      2.times { breaker.report_requeue! }
      breaker.report_success!
      2.times { breaker.report_requeue! }

      refute breaker.open?
    end

    def test_failure_resets_consecutive_requeues
      breaker = max_consecutive_requeues(max: 3)

      2.times { breaker.report_requeue! }
      breaker.report_failure!
      2.times { breaker.report_requeue! }

      refute breaker.open?
    end

    def test_non_consecutive_requeues_do_not_open_breaker
      breaker = max_consecutive_requeues(max: 3)

      breaker.report_requeue!
      breaker.report_requeue!
      breaker.report_success!
      breaker.report_requeue!

      refute breaker.open?
    end

    def test_max_consecutive_requeues_message_is_specific
      message = max_consecutive_requeues.message

      assert_match(/consecutive tests/, message)
      assert_match(/requeued/, message)
      refute_match(/test failures/, message)
    end

    def test_requeues_do_not_increment_or_reset_consecutive_failures
      breaker = CircuitBreaker::MaxConsecutiveFailures.new(max_consecutive_failures: 2)

      breaker.report_failure!
      breaker.report_requeue!
      refute breaker.open?

      breaker.report_failure!
      assert breaker.open?
    end

    def test_all_breakers_accept_requeue_events
      breakers = [
        CircuitBreaker::Disabled,
        CircuitBreaker::Timeout.new(duration: 60),
        CircuitBreaker::MaxConsecutiveFailures.new(max_consecutive_failures: 2),
        max_consecutive_requeues,
      ]

      breakers.each do |breaker|
        assert_respond_to breaker, :report_requeue!
      end
    end

    private

    def max_consecutive_requeues(max: 2)
      CircuitBreaker::MaxConsecutiveRequeues.new(max_consecutive_requeues: max)
    end
  end
end
