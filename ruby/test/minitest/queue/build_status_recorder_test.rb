# frozen_string_literal: true
require 'test_helper'
require 'concurrent/set'

module Minitest::Queue
  # Lightweight stand-in for a test object in unit tests that don't run real tests.
  # Holds test_id and file_path directly so no source_location lookup is needed.
  FakeEntry = Struct.new(:id, :queue_entry, :method_name)

  def self.fake_entry(method_name)
    test_id = "Minitest::Test##{method_name}"
    # Use the same file_path as ReporterTestHelper#result so entries match across reserve/record calls
    file_path = "#{Minitest::Queue.project_root}/test/my_test.rb"
    FakeEntry.new(test_id, CI::Queue::QueueEntry.format(test_id, file_path), method_name)
  end

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
      reserve(@queue, "a")
      @reporter.record(result('a', failure: "Something went wrong"))
      reserve(@queue, "b")
      @reporter.record(result('b', unexpected_error: true))
      reserve(@queue, "h")
      @reporter.record(result('h', failure: "Something went wrong", requeued: true))

      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start

      reserve(second_queue, "c")
      second_reporter.record(result('c', failure: "Something went wrong"))
      reserve(second_queue, "d")
      second_reporter.record(result('d', unexpected_error: true))
      reserve(second_queue, "e")
      second_reporter.record(result('e', skipped: true))
      reserve(second_queue, "f")
      second_reporter.record(result('f', unexpected_error: true))
      reserve(second_queue, "g")
      second_reporter.record(result('g', requeued: true))
      reserve(second_queue, "h")
      second_reporter.record(result('h', skipped: true, requeued: true))
      # W2 passes "b" (W1 had errored): stat correction subtracts W1's error. W2 records h as requeue (not success), so h stays in error_reports.
      reserve(second_queue, "b")
      second_reporter.record(result('b'))

      # 9 runs × 1 assertion each (helper sets runnable.assertions += 1); real assertion count from delta_for
      assert_equal 9, summary.assertions
      # W1: a, h (2 failures). W2: c. h's error report is not replaced (W2 recorded requeue), so no correction for h.
      assert_equal 3, summary.failures
      assert_equal 2, summary.errors
      assert_equal 1, summary.skips
      assert_equal 2, summary.requeues
      # a, c, d, f, and h (W2 recorded h as requeue, so h's error report was not replaced/deleted)
      assert_equal 5, summary.error_reports.size
      # W2's success on "b" replaced W1's error, so record_flaky("b") was called
      assert_equal 1, summary.flaky_reports.size
    end

    def test_retrying_test
      yielded = false

      test = nil

      @queue.poll do |_test|
        test = _test
        assert_equal "a", test.method_name
        @reporter.record(result(test.method_name, failure: "Something went wrong"))

        assert_equal 1, summary.error_reports.size

        yielded = true
        break
      end

      assert yielded, "@queue.poll didn't yield"

      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start

      # pretend we reserved the same test again
      reserve(second_queue, "a")
      second_reporter.record(result("a"))
      assert_equal 0, summary.error_reports.size
      assert_equal 1, @queue.test_failed
      # Second worker's record_success returned false (duplicate ack), so local counters were not incremented
      assert_equal 0, second_reporter.skips
    end

    def test_retrying_test_reverse
      yielded = false

      test = nil

      @queue.poll do |_test|
        test = _test
        assert_equal "a", test.method_name
        @reporter.record(result(test.method_name))

        assert_equal 0, summary.error_reports.size

        yielded = true
        break
      end

      assert yielded, "@queue.poll didn't yield"

      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start

      # pretend we reserved the same test again
      reserve(second_queue, "a")
      second_reporter.record(result("a", failure: "Something went wrong"))
      assert_equal 0, summary.error_reports.size
      assert_equal 0, @queue.test_failed
      # Second worker's record_error returned false (duplicate ack), so local counters were not incremented
      assert_equal 0, second_reporter.failures
    end

    def test_static_queue_record_success
      static_queue = CI::Queue::Static.new(['test_example'], CI::Queue::Configuration.new(build_id: '42', worker_id: '1'))
      static_reporter = BuildStatusRecorder.new(build: static_queue.build)
      static_reporter.start

      static_reporter.record(result('test_example'))

      assert_equal 1, static_reporter.assertions
      assert_equal 0, static_reporter.failures
      assert_equal 0, static_reporter.errors
      assert_equal 0, static_reporter.skips
      assert_equal 0, static_reporter.requeues
    end

    def test_duplicate_success_does_not_increment_skips
      # Worker 1 records success for "a" first
      reserve(@queue, "a")
      @reporter.record(result("a", skipped: true))
      assert_equal 1, @reporter.skips

      # Worker 2 records success for same test "a" (duplicate ack)
      second_queue = worker(2)
      second_reporter = BuildStatusRecorder.new(build: second_queue.build)
      second_reporter.start
      reserve(second_queue, "a")
      second_reporter.record(result("a", skipped: true))

      # Second reporter did not increment skips because record_success returned false
      assert_equal 0, second_reporter.skips
    end

    def test_build_record_methods_return_boolean
      # Redis build: first to ack returns true, duplicate returns false
      reserve(@queue, "a")
      entry_a = Minitest::Queue.fake_entry("a").queue_entry
      assert_equal true, @queue.build.record_success(entry_a)
      entry_b = Minitest::Queue.fake_entry("b").queue_entry
      assert_equal true, @queue.build.record_requeue(entry_b)

      second_queue = worker(2)
      reserve(second_queue, "a")
      assert_equal false, second_queue.build.record_success(entry_a)
    end

    def test_static_build_record_returns_true
      static_queue = CI::Queue::Static.new(['test_example'], CI::Queue::Configuration.new(build_id: '42', worker_id: '1'))
      build = static_queue.build

      entry = CI::Queue::QueueEntry.format("test_example", __FILE__)
      assert_equal true, build.record_success(entry)
      assert_equal true, build.record_requeue(entry)
      assert_equal true, build.record_error(entry, "payload")
    end

    private

    def reserve(queue, method_name)
      entry = Minitest::Queue.fake_entry(method_name)
      queue.instance_variable_set(:@reserved_tests, Concurrent::Set.new([entry.id]))
      reserved_entries = queue.instance_variable_get(:@reserved_entries) || Concurrent::Map.new
      reserved_entries[entry.id] = entry.queue_entry
      queue.instance_variable_set(:@reserved_entries, reserved_entries)
    end

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

    def summary
      @summary ||= Minitest::Queue::BuildStatusReporter.new(supervisor: @queue.supervisor)
    end
  end
end
