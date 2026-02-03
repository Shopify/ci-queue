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
      )
    end

    assert_predicate queue, :lazy_load?
  ensure
    cleanup_temp_test_classes
  end

  def test_populate_lazy_leader_loads_files_and_builds_manifest
    @redis.flushdb
    queue = worker(1, lazy_load: true, populate: false, build_id: 'lazy-2')
    test_files = create_temp_test_files

    output, _ = capture_io do
      queue.populate_lazy(
        test_files: test_files,
        random: Random.new(0),
        config: queue.send(:config),
      )
    end

    assert_predicate queue, :master?
    assert_match(/Leader loaded/, output)
    assert_match(/test files/, output)
    assert_match(/tests/, output)

    # Verify manifest was stored in Redis
    manifest_key = CI::Queue::Redis::KeyShortener.key('lazy-2', 'manifest')
    manifest = @redis.hgetall(manifest_key)
    refute_empty manifest
    assert manifest.key?('LazyTestA')
    assert manifest.key?('LazyTestB')
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
        )
      end
    end

    assert_match(/Failed to load test file/, error.message)
  end

  # Note: We can't easily test "no tests found" because Minitest.loaded_tests
  # returns ALL loaded tests, including from the test framework itself.
  # The error handling is tested via the lazy_loader_test.rb unit tests instead.

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
