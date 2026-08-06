# frozen_string_literal: true

require 'test_helper'

module Minitest::Queue
  class ParallelWorkerMetadataTest < Minitest::Test
    include ReporterTestHelper

    ENV_KEY = 'CI_QUEUE_PARALLEL_WORKER_ID'

    def setup
      @original_env = ENV.delete(ENV_KEY)
      @original_worker_id = Minitest::Queue.instance_variable_get(:@parallel_worker_id)
      Minitest::Queue.parallel_worker_id = nil
    end

    def teardown
      @original_env ? ENV[ENV_KEY] = @original_env : ENV.delete(ENV_KEY)
      Minitest::Queue.parallel_worker_id = @original_worker_id
    end

    def test_stamps_pid_and_monotonic_per_process_index
      first = result('test_foo')
      second = result('test_bar')

      Minitest::Queue.stamp_parallel_worker_metadata(first)
      Minitest::Queue.stamp_parallel_worker_metadata(second)

      assert_equal Process.pid, first.parallel_worker_pid
      assert_equal Process.pid, second.parallel_worker_pid
      assert_kind_of Integer, first.parallel_worker_test_index
      assert_equal first.parallel_worker_test_index + 1, second.parallel_worker_test_index
    end

    def test_worker_id_is_nil_by_default
      test = result('test_foo')
      Minitest::Queue.stamp_parallel_worker_metadata(test)

      assert_nil test.parallel_worker_id
    end

    def test_worker_id_from_setter
      Minitest::Queue.parallel_worker_id = 3

      test = result('test_foo')
      Minitest::Queue.stamp_parallel_worker_metadata(test)

      assert_equal 3, test.parallel_worker_id
    end

    def test_worker_id_from_env
      ENV[ENV_KEY] = '7'

      test = result('test_foo')
      Minitest::Queue.stamp_parallel_worker_metadata(test)

      assert_equal 7, test.parallel_worker_id
    end

    def test_setter_takes_precedence_over_env
      ENV[ENV_KEY] = '7'
      Minitest::Queue.parallel_worker_id = 3

      assert_equal 3, Minitest::Queue.parallel_worker_id
    end

    def test_non_numeric_env_worker_id_is_passed_through
      ENV[ENV_KEY] = 'worker-a'

      assert_equal 'worker-a', Minitest::Queue.parallel_worker_id
    end

    def test_empty_env_worker_id_is_nil
      ENV[ENV_KEY] = ''

      assert_nil Minitest::Queue.parallel_worker_id
    end

    def test_index_restarts_when_pid_changes
      # Prime the counter in this process.
      Minitest::Queue.stamp_parallel_worker_metadata(result('test_foo'))

      # Simulate a fork: pretend the counter belongs to another process.
      Minitest::Queue.instance_variable_set(:@parallel_worker_metadata_pid, Process.pid - 1)

      test = result('test_bar')
      Minitest::Queue.stamp_parallel_worker_metadata(test)

      assert_equal 0, test.parallel_worker_test_index
      assert_equal Process.pid, test.parallel_worker_pid
    end

    def test_ignores_results_without_accessors
      plain = Object.new
      Minitest::Queue.stamp_parallel_worker_metadata(plain) # does not raise
    end

    def test_does_not_overwrite_worker_side_stamps
      # Simulates an embedding environment (e.g. Rails parallel testing over
      # DRb) where the worker stamped the result before sending it to the
      # process running the reporters: the reporting-side stamp in
      # handle_test_result must not clobber it.
      stamped = result('test_foo')
      stamped.parallel_worker_id = 9
      stamped.parallel_worker_test_index = 4
      stamped.parallel_worker_pid = 4242

      before = result('test_before')
      Minitest::Queue.stamp_parallel_worker_metadata(before)
      Minitest::Queue.stamp_parallel_worker_metadata(stamped)
      after = result('test_after')
      Minitest::Queue.stamp_parallel_worker_metadata(after)

      assert_equal 9, stamped.parallel_worker_id
      assert_equal 4, stamped.parallel_worker_test_index
      assert_equal 4242, stamped.parallel_worker_pid

      # The local per-process counter must not advance for pre-stamped results.
      assert_equal before.parallel_worker_test_index + 1, after.parallel_worker_test_index
    end
  end
end
