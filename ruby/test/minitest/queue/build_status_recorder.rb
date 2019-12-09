# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class BuildStatusRecorderTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
      @redis = ::Redis.new(url: @redis_url)
      @redis.flushdb
      @queue = worker(1)
      @reporter = BuildStatusRecorder.new(build: @queue.build)
      @reporter.start
    end

    def test_aggregation
      @reporter.record(result('a', Minitest::Assertion.new))
      @reporter.record(result('b', Minitest::UnexpectedError.new(StandardError.new)))

      second_queue = worker(2)
      second_reporter = second_queue
      second_reporter.start

      second_reporter.record(result('c', Minitest::Assertion.new))
      second_reporter.record(result('d', Minitest::UnexpectedError.new(StandardError.new)))
      second_reporter.record(result('e', Minitest::Skip.new))
      second_reporter.record(result('f', Minitest::UnexpectedError.new(StandardError.new)))

      assert_equal 6, summary.assertions
      assert_equal 2, summary.failures
      assert_equal 3, summary.errors
      assert_equal 1, summary.skips
      assert_equal 5, summary.error_reports.size
    end

    def test_retrying_test
      @reporter.record(result('a', Minitest::Assertion.new))
      assert_equal 1, summary.error_reports.size

      second_queue = worker(2)
      second_reporter = second_queue
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
