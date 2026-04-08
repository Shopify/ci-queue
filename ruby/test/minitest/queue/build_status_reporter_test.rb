# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class BuildStatusReporterTest < Minitest::Test
    include ReporterTestHelper
    include QueueHelper

    def setup
      @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
      @redis = ::Redis.new(url: @redis_url)
      @redis.flushdb
      @supervisor = supervisor
      @recorder = BuildStatusRecorder.new(build: @supervisor.build)
      @reporter = BuildStatusReporter.new(supervisor: @supervisor)
    end

    def test_timing_out_waiting_for_tests
      queue = worker(1)
      exit_status = nil

      queue.poll do |_test|
        queue.shutdown!
      end

      @supervisor.instance_variable_set(:@time_left, 0)

      out, _ = capture_subprocess_io do
        exit_status = @reporter.report
      end

      assert_equal 43, exit_status
      assert_includes out, "Timed out waiting for tests to be executed."
    end

    def test_all_workers_died
      queue = worker(1)
      exit_status = nil

      queue.poll do |_test|
        queue.shutdown!
      end

      @supervisor.instance_variable_set(:@time_left, 1)
      @supervisor.instance_variable_set(:@time_left_with_no_workers, 0)

      out, _ = capture_subprocess_io do
        exit_status = @reporter.report
      end

      assert_equal 45, exit_status
      assert_includes out, "All workers died."
    end

    def test_aggregate_floors_failures_to_error_reports_when_stats_are_zero
      # Simulate a worker that recorded a test failure in error-reports but died
      # before flushing its per-worker stats (stats show 0 failures).
      queue = worker(1)
      queue.poll { |_test| queue.shutdown! }

      entry = CI::Queue::QueueEntry.format("FakeTest#test_failure", "/tmp/fake_test.rb")
      payload = Minitest::Queue::ErrorReport.new(
        test_name: "test_failure",
        test_suite: "FakeTest",
        test_file: "/tmp/fake_test.rb",
        test_line: 1,
        error_class: "RuntimeError",
        output: "FakeTest#test_failure: failed",
      ).dump
      @redis.hset("build:42:error-reports", entry, payload)

      @supervisor.instance_variable_set(:@time_left, 1)
      @supervisor.instance_variable_set(:@time_left_with_no_workers, 0)

      out, _ = capture_subprocess_io do
        @reporter.report
      end

      assert_includes out, "1 failures,", "should floor failure count to error_reports.size"
      refute_includes out, "0 failures, 0 errors,", "should not show misleadingly green zero-failure line"
    end

    private

    def worker(id)
      result = nil
      capture_io do
        result = CI::Queue::Redis.new(
          @redis_url,
          CI::Queue::Configuration.new(
            build_id: '42',
            worker_id: id.to_s,
            timeout: 0.2,
          ),
        ).populate([Minitest::Queue.fake_entry("a")])
      end
      result
    end

    def supervisor(timeout: 30, queue_init_timeout: nil)
      CI::Queue::Redis::Supervisor.new(
        @redis_url,
        CI::Queue::Configuration.new(
          build_id: '42',
          timeout: timeout,
          queue_init_timeout: queue_init_timeout
        ),
      )
    end
  end
end
