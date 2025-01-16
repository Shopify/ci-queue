# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class BuildStatusRecorderTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
      @redis = ::Redis.new(url: @redis_url)
      @redis.flushdb
      @queue = worker(1)
      @reporter = BuildStatusRecorder.new(build: @queue.build)
      @reporter.start
    end

    def test_aggregation
      @reporter.record(result('a', failure: "Something went wrong"))
      @reporter.record(result('b', unexpected_error: true))
      @reporter.record(result('h', failure: "Something went wrong", requeued: true))

      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start

      second_reporter.record(result('c', failure: "Something went wrong"))
      second_reporter.record(result('d', unexpected_error: true))
      second_reporter.record(result('e', skipped: true))
      second_reporter.record(result('f', unexpected_error: true))
      second_reporter.record(result('g', requeued: true))
      second_reporter.record(result('h', skipped: true, requeued: true))

      assert_equal 9, summary.assertions
      assert_equal 3, summary.failures
      assert_equal 3, summary.errors
      assert_equal 2, summary.skips
      assert_equal 1, summary.requeues
      assert_equal 5, summary.error_reports.size
      assert_equal 0, summary.flaky_reports.size
      assert_equal 2, summary.skipped_reports.size
    end

    def test_retrying_test
      @reporter.record(result('a', failure: "Something went wrong"))
      assert_equal 1, summary.error_reports.size

      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start

      second_reporter.record(result('a'))
      assert_equal 0, summary.error_reports.size
    end

    private

    def worker(id)
      CI::Queue::Redis.new(
        @redis_url,
        CI::Queue::Configuration.new(
          build_id: '42',
          worker_id: id.to_s,
          timeout: 0.2,
        ),
      ).populate([])
    end

    def summary
      @summary ||= Minitest::Queue::BuildStatusReporter.new(build: @queue.supervisor.build)
    end
  end
end
