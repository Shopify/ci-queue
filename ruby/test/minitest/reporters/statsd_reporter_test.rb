# frozen_string_literal: true
require 'test_helper'
require 'minitest/reporters/statsd_reporter'

module Minitest::Reporters
  class StatsdReporterTest < Minitest::Test
    include ReporterTestHelper

    class FakeStatsD
      attr_reader :increments

      def initialize(*)
        @increments = {}
      end

      def increment(tag)
        @increments[tag] ||= 0
        @increments[tag] += 1
      end
    end

    def setup
      @reporter = Minitest::Reporters::StatsdReporter.new(statsd: FakeStatsD)
    end

    def test_statsd_incremented_as_expected
      passed = result('a')
      failed = result('b', failure: 'Failed')
      skipped = result('c', skipped: true)
      error = result('d', unexpected_error: true)
      requeued = result('e', requeued: true)

      @reporter.record(passed)
      @reporter.record(failed)
      @reporter.record(skipped)
      @reporter.record(error)
      @reporter.record(requeued)

      assert_equal 1, @reporter.statsd.increments['passed']
      assert_equal 2, @reporter.statsd.increments['failed'] # Requeue also counts as a failure
      assert_equal 1, @reporter.statsd.increments['skipped']
      assert_equal 1, @reporter.statsd.increments['unexpected_errors']
      assert_equal 1, @reporter.statsd.increments['requeued']
    end

    def test_failing_infrastructure_threshold_submits_on_report
      Minitest::Reporters::StatsdReporter::FAILING_INFRASTRUCTURE_THRESHOLD.times do
        failed = result('b', failure: 'Failed')
        @reporter.record(failed)
      end

      @reporter.report

      assert_equal Minitest::Reporters::StatsdReporter::FAILING_INFRASTRUCTURE_THRESHOLD,
        @reporter.statsd.increments['failed']
      assert_equal 1, @reporter.statsd.increments['failing_infrastructure_threshold']
    end
  end
end
