# frozen_string_literal: true
require 'minitest/queue'
require 'minitest/queue/statsd'
require 'minitest/reporters'

module Minitest
  module Reporters
    class StatsdReporter < Minitest::Reporters::BaseReporter
      FAILING_INFRASTRUCTURE_THRESHOLD = 10

      attr_reader :statsd

      def initialize(statsd: Minitest::Queue::Statsd, statsd_endpoint: nil, **options)
        super(options)
        @statsd = statsd.new(
          addr: statsd_endpoint,
          namespace: 'minitests.tests',
          default_tags: ["slug:#{ENV['BUILDKITE_PROJECT_SLUG']}"]
        )
        @failures = 0
      end

      def record(result)
        if result.passed?
          @statsd.increment("passed")
        elsif result.skipped? && !result.requeued?
          @statsd.increment("skipped")
        else
          @statsd.increment('requeued') if result.requeued?

          if result.failure.is_a?(Minitest::UnexpectedError)
            @statsd.increment("unexpected_errors")
          else
            @statsd.increment("failed")
          end

          @failures += 1
        end
      end

      def report
        @statsd.increment("failing_infrastructure_threshold") if @failures >= FAILING_INFRASTRUCTURE_THRESHOLD
      end
    end
  end
end
