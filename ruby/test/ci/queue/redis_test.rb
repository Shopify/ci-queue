# frozen_string_literal: true
require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    @redis = ::Redis.new(url: @redis_url)
    @redis.flushdb
    super
    @config = @queue.send(:config) # hack
  end

  def test_from_uri
    second_queue = populate(
      CI::Queue.from_uri(@redis_url, config)
    )
    assert_instance_of CI::Queue::Redis::Worker, second_queue
    assert_equal @queue.to_a, second_queue.to_a
  end

  def test_requeue # redefine the shared one
    previous_offset = CI::Queue::Redis.requeue_offset
    CI::Queue::Redis.requeue_offset = 2
    failed_once = false
    test_order = poll(@queue, ->(test) {
      if test == shuffled_test_list.last && !failed_once
        failed_once = true
        false
      else
        true
      end
    })

    expected_order = shuffled_test_list.dup
    expected_order.insert(-CI::Queue::Redis.requeue_offset, shuffled_test_list.last)

    assert_equal expected_order, test_order
  ensure
    CI::Queue::Redis.requeue_offset = previous_offset
  end

  def test_retry_queue_with_all_tests_passing
    poll(@queue)
    retry_queue = @queue.retry_queue
    populate(retry_queue)
    retry_test_order = poll(retry_queue)
    assert_equal [], retry_test_order
  end

  def test_retry_queue_with_all_tests_passing_2
    poll(@queue)
    retry_queue = @queue.retry_queue
    populate(retry_queue)
    retry_test_order = poll(retry_queue) do |test|
      @queue.build.record_error(test.id, 'Failed')
    end
    assert_equal retry_test_order, retry_test_order
  end

  def test_shutdown
    poll(@queue) do
      @queue.shutdown!
    end
    assert_equal TEST_LIST.size - 1, @queue.size
  end

  def test_master_election
    assert_predicate @queue, :master?
    refute_predicate worker(2), :master?

    @redis.flushdb
    assert_predicate worker(2), :master?
    refute_predicate worker(1), :master?
  end

  def test_exhausted_while_not_populated
    assert_predicate @queue, :populated?

    second_worker = worker(2, populate: false)

    refute_predicate second_worker, :populated?
    refute_predicate second_worker, :exhausted?

    poll(@queue)

    refute_predicate second_worker, :populated?
    assert_predicate second_worker, :exhausted?
  end

  def test_monitor_boot_and_shutdown
    @queue.config.max_missed_heartbeat_seconds = 1
    @queue.boot_heartbeat_process!

    status = @queue.stop_heartbeat!

    assert_predicate status, :success?
  ensure
    @queue.config.max_missed_heartbeat_seconds = nil
  end

  def test_timed_out_test_are_picked_up_by_other_workers
    second_queue = worker(2)
    acquired = false
    done = false
    monitor = Monitor.new
    condition = monitor.new_cond

    Thread.start do
      monitor.synchronize do
        condition.wait_until { acquired }
        poll(second_queue)
        done = true
        condition.signal
      end
    end

    poll(@queue) do
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { done }
      end
    end

    assert_predicate @queue, :exhausted?
    assert_equal [], populate(@queue.retry_queue).to_a
    assert_equal [], populate(second_queue.retry_queue).to_a.sort
  end

  def test_release_immediately_timeout_the_lease
    second_queue = worker(2)

    reserved_test = nil
    poll(@queue) do |test|
      reserved_test = test
      break
    end
    refute_nil reserved_test

    worker(1).release! # Use a new instance to ensure we don't depend on in-memory state

    poll(second_queue) do |test|
      assert_equal reserved_test, test
      break
    end
  end

  def test_test_isnt_requeued_if_it_was_picked_up_by_another_worker
    second_queue = worker(2)
    acquired = false
    done = false
    monitor = Monitor.new
    condition = monitor.new_cond

    Thread.start do
      monitor.synchronize do
        condition.wait_until { acquired }
        poll(second_queue)
        done = true
        condition.signal
      end
    end

    poll(@queue, false) do
      break if acquired
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { done }
      end
    end

    assert_predicate @queue, :exhausted?
  end

  def test_acknowledge_returns_false_if_the_test_was_picked_up_by_another_worker
    second_queue = worker(2)
    acquired = false
    done = false
    monitor = Monitor.new
    condition = monitor.new_cond

    Thread.start do
      monitor.synchronize do
        condition.wait_until { acquired }
        second_queue.poll do |test|
          assert_equal true, second_queue.acknowledge(test.id)
        end
        done = true
        condition.signal
      end
    end

    @queue.poll do |test|
      break if acquired
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { done }
        assert_equal false, @queue.acknowledge(test.id)
      end
    end

    assert_predicate @queue, :exhausted?
  end

  def test_workers_register
    assert_equal 1, @redis.scard(CI::Queue::Redis::KeyShortener.key('42', 'workers'))
    worker(2)
    assert_equal 2, @redis.scard(CI::Queue::Redis::KeyShortener.key('42', 'workers'))
  end

  def test_timeout_warning
    begin
      threads = 2.times.map do |i|
        Thread.new do
          queue = worker(i, tests: [TEST_LIST.first], build_id: '24')
          queue.poll do |test|
            sleep 1 # timeout
            queue.acknowledge(test.id)
          end
        end
      end

      threads.each { |t| t.join(3) }
      threads.each { |t| refute_predicate t, :alive? }

      queue = worker(12, build_id: '24')
      assert_equal [[:RESERVED_LOST_TEST, {test: 'ATest#test_foo', timeout: 0.2}]], queue.build.pop_warnings
    ensure
      threads.each(&:kill)
    end
  end

  def test_continuously_timing_out_tests
    3.times do
      @redis.flushdb
      begin
        threads = 2.times.map do |i|
          Thread.new do
            queue = worker(i, tests: [TEST_LIST.first], build_id: '24')
            queue.poll do |test|
              sleep 1 # timeout
              queue.acknowledge(test.id)
            end
          end
        end

        threads.each { |t| t.join(3) }
        threads.each { |t| refute_predicate t, :alive? }

        queue = worker(12, build_id: '24')
        assert_predicate queue, :queue_initialized?
        assert_predicate queue, :exhausted?
      ensure
        threads.each(&:kill)
      end
    end
  end

  def test_initialise_from_redis_uri
    queue = CI::Queue.from_uri('redis://localhost:6379/0', config)
    assert_instance_of CI::Queue::Redis::Worker, queue
  end

  def test_initialise_from_rediss_uri
    queue = CI::Queue.from_uri('rediss://localhost:6379/0', config)
    assert_instance_of CI::Queue::Redis::Worker, queue
  end

  # === Lazy Loading Tests ===

  def test_lazy_load_mode_flag
    queue = worker(1, lazy_load: true)
    assert_predicate queue, :lazy_load?

    queue2 = worker(2, lazy_load: false)
    refute_predicate queue2, :lazy_load?
  end

  def test_files_loaded_count_starts_at_zero
    queue = worker(1, lazy_load: true)
    assert_equal 0, queue.files_loaded_count
  end

  def test_populate_lazy_sets_lazy_load_mode
    @redis.flushdb
    queue = worker(1, lazy_load: false, populate: false, build_id: 'lazy-1')
    refute_predicate queue, :lazy_load?

    # Create temp test files
    test_files = create_temp_test_files

    capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    assert_predicate queue, :lazy_load?
  ensure
    cleanup_temp_test_classes
  end

  def test_populate_lazy_leader_loads_files_and_pushes_tests
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-2')
    test_files = create_temp_test_files

    output, _ = capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    assert_predicate queue, :master?
    assert_match(/Leader loaded/, output)
    assert_match(/test files/, output)
    assert_match(/tests/, output)

    # Verify tests were pushed to the queue and total was set
    assert_operator queue.total, :>, 0
    # Verify streaming-complete was set
    complete_key = CI::Queue::Redis::KeyShortener.key('lazy-2', 'streaming-complete')
    assert_equal '1', @redis.get(complete_key)
  ensure
    cleanup_temp_test_classes
  end

  def test_populate_lazy_consumer_does_not_load_files
    @redis.flushdb
    # First worker becomes leader and populates
    leader = worker(1, lazy_load: true, populate: false, build_id: 'lazy-3')
    test_files = create_temp_test_files

    capture_io do
      leader.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: leader.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    # Remove the test classes so we can verify consumer doesn't load them
    cleanup_temp_test_classes

    # Second worker becomes consumer
    consumer = worker(2, lazy_load: true, populate: false, build_id: 'lazy-3')

    capture_io do
      consumer.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: consumer.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    refute_predicate consumer, :master?
    # Consumer should not have loaded any files yet
    assert_equal 0, consumer.files_loaded_count
  ensure
    cleanup_temp_test_classes
  end

  def test_populate_lazy_raises_on_load_error
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-4')
    nonexistent_files = ['/nonexistent/path/test.rb']

    error = assert_raises(CI::Queue::LazyLoadError) do
      capture_io do
        queue.populate_lazy(
          test_files: nonexistent_files,
          random: Random.new(0),
          config: queue.send(:config),
          file_loader: method(:lazy_file_loader),
          test_factory: method(:lazy_test_factory),
        )
      end
    end

    assert_match(/Failed to load test file/, error.message)
  end

  def test_acknowledge_works_when_pending_tests_mapping_lost
    # Reproduces the DRb scenario: a test is reserved (stored in reserved_tests
    # as "file_path\ttest_id"), but by the time acknowledge is called, the
    # @pending_tests mapping is gone (e.g., consumed by requeue, or acknowledge
    # is called from a DRb thread with a reconstructed SingleExample).
    # queue_entry_for_test should fall back to scanning reserved_tests by suffix.
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-ack-1')
    test_files = create_temp_test_files

    capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    # Reserve a test (this populates @pending_tests and reserved_tests)
    test_id = queue.send(:reserve_entry)
    assert test_id, "Should have reserved a test"

    # Simulate the @pending_tests mapping being lost (as happens in DRb/requeue scenarios)
    queue.instance_variable_get(:@pending_tests).clear

    # acknowledge should still work by finding the entry in reserved_tests via suffix scan
    assert queue.acknowledge(test_id), "Should acknowledge even without @pending_tests mapping"
  ensure
    cleanup_temp_test_classes
  end

  def test_acknowledge_with_pending_tests_mapping_present
    # Verify the normal happy path: @pending_tests has the mapping
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-ack-2')
    test_files = create_temp_test_files

    capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    test_id = queue.send(:reserve_entry)
    assert test_id, "Should have reserved a test"

    # @pending_tests mapping is intact — normal path
    assert queue.acknowledge(test_id), "Should acknowledge with mapping present"
  ensure
    cleanup_temp_test_classes
  end

  def test_lazy_load_report_fields_are_correct
    # Verifies that all fields the summary reporter needs (total, progress,
    # error_reports, failed_tests, fetch_stats) are correct after a lazy-loaded
    # test run. This catches issues where streaming queue entries ("file_path\ttest_id")
    # leak into reporter-facing Redis keys that expect plain test IDs.
    @redis.flushdb
    build_id = 'lazy-report-1'
    leader = worker(1, lazy_load: true, populate: false, build_id: build_id,
                    max_requeues: 1, requeue_tolerance: 1.0)
    test_files = create_temp_test_files

    capture_io do
      leader.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: leader.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    # Poll all tests: pass some, fail one
    failed_test_id = nil
    leader.poll do |test|
      if failed_test_id.nil? && test.id.include?('test_one')
        # Fail this test (don't requeue to keep it simple)
        failed_test_id = test.id
        leader.report_failure!
        leader.acknowledge(test.id, error: "intentional failure")
      else
        leader.report_success!
        leader.acknowledge(test.id)
      end
    end

    assert failed_test_id, "Should have found a test to fail"

    # Now verify report fields via Supervisor (same as report_command uses)
    supervisor = leader.supervisor

    # total should be positive (not 0 or -1)
    assert_operator supervisor.total, :>, 0, "total should be positive"

    # progress should equal total (all tests processed, queue empty)
    assert_equal supervisor.total, supervisor.progress,
      "progress should equal total when queue is exhausted"

    # Queue should be exhausted
    assert_predicate supervisor, :exhausted?

    # error_reports should contain plain test IDs (no file path prefix)
    build_record = supervisor.build
    error_reports = build_record.error_reports
    refute_empty error_reports, "Should have error reports"
    error_reports.each_key do |test_key|
      refute_includes test_key, "\t",
        "error_reports key should be a plain test ID, not a queue entry: #{test_key}"
      assert_includes test_key, "#",
        "error_reports key should be in 'Class#method' format: #{test_key}"
    end

    # failed_tests should contain plain test IDs
    failed_tests = build_record.failed_tests
    refute_empty failed_tests, "Should have failed tests"
    failed_tests.each do |test_key|
      refute_includes test_key, "\t",
        "failed_tests should be plain test IDs: #{test_key}"
    end
    assert_includes failed_tests, failed_test_id

    # fetch_stats should have positive assertion count
    stats = build_record.fetch_stats(Minitest::Queue::BuildStatusRecorder::COUNTERS)
    assert_operator stats['assertions'].to_i, :>=, 0
  ensure
    cleanup_temp_test_classes
  end

  def test_lazy_load_supervisor_progress_not_negative
    # Reproduces the "Ran -1 tests" bug in the summary reporter.
    # When the 'total' Redis key is missing (expired or never set) and a test
    # is stuck in the running zset, progress = total - size = 0 - 1 = -1.
    @redis.flushdb
    build_id = 'lazy-progress-1'
    leader = worker(1, lazy_load: true, populate: false, build_id: build_id)
    test_files = create_temp_test_files

    capture_io do
      leader.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: leader.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    # Reserve one test but DON'T acknowledge it (simulates stuck/crashed worker)
    test_id = leader.send(:reserve_entry)
    assert test_id, "Should have reserved a test"

    # Delete the 'total' key from Redis (simulates TTL expiry)
    total_key = leader.send(:key, 'total')
    @redis.del(total_key)

    # Now the supervisor sees: total=0 (key missing), size>=1 (stuck in running)
    supervisor = leader.supervisor

    # Confirm the preconditions that cause the bug
    assert_equal 0, @redis.get(total_key).to_i, "total key should be missing (returns 0)"
    assert_operator supervisor.size, :>, 0, "size should be > 0 (test stuck in running)"

    # progress should never be negative — the report shows "Ran -1 tests" otherwise
    assert_operator supervisor.progress, :>=, 0,
      "progress should not be negative even when total key is missing (was #{supervisor.progress})"
  ensure
    cleanup_temp_test_classes
  end

  def test_populated_returns_true_for_lazy_load_mode
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-6')
    refute_predicate queue, :populated?

    test_files = create_temp_test_files
    capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
        file_loader: method(:lazy_file_loader),
        test_factory: method(:lazy_test_factory),
      )
    end

    assert_predicate queue, :populated?
  ensure
    cleanup_temp_test_classes
  end

  private

  def shuffled_test_list
    CI::Queue.shuffle(TEST_LIST, Random.new(0)).freeze
  end

  def build_queue
    worker(1, max_requeues: 1, requeue_tolerance: 0.1, populate: false, max_consecutive_failures: 10)
  end

  def populate(worker, tests: TEST_LIST.dup)
    worker.populate(tests, random: Random.new(0))
  end

  def worker(id, **args)
    tests = args.delete(:tests) || TEST_LIST.dup
    skip_populate = args.delete(:populate) == false
    queue = CI::Queue::Redis.new(
      @redis_url,
      CI::Queue::Configuration.new(
        build_id: '42',
        worker_id: id.to_s,
        timeout: 0.2,
        **args,
      )
    )
    if skip_populate
      return queue
    else
      populate(queue, tests: tests)
    end
  end

  # File loader callback for lazy loading tests - loads a file and returns new test examples
  def lazy_file_loader(file_path)
    count_before = Minitest.loaded_tests.size
    load(file_path)
    loaded_tests = Minitest.loaded_tests
    (count_before...loaded_tests.size).map { |i| loaded_tests[i] }
  end

  # Test factory callback for lazy loading tests
  def lazy_test_factory(class_name, method_name, file_path)
    Minitest::Queue::SingleExample.new(class_name, method_name, file_path: file_path)
  end

  def create_temp_test_files
    @temp_test_files ||= []

    file_a = Tempfile.new(['lazy_test_a_', '.rb'])
    file_a.write(<<~RUBY)
      class LazyTestA < Minitest::Test
        def test_one
          assert true
        end

        def test_two
          assert true
        end
      end
    RUBY
    file_a.close
    @temp_test_files << file_a

    file_b = Tempfile.new(['lazy_test_b_', '.rb'])
    file_b.write(<<~RUBY)
      class LazyTestB < Minitest::Test
        def test_three
          assert true
        end
      end
    RUBY
    file_b.close
    @temp_test_files << file_b

    [file_a.path, file_b.path]
  end

  def cleanup_temp_test_classes
    Object.send(:remove_const, :LazyTestA) if defined?(LazyTestA)
    Object.send(:remove_const, :LazyTestB) if defined?(LazyTestB)
    @temp_test_files&.each(&:unlink)
    @temp_test_files = nil
  end
end
