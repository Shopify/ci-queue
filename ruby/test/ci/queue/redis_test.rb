# frozen_string_literal: true
require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  EntryTest = Struct.new(:id, :queue_entry)

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
      @queue.build.record_error(test.queue_entry, 'Failed')
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
          assert_equal true, second_queue.acknowledge(test.queue_entry)
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
        assert_equal false, @queue.acknowledge(test.queue_entry)
      end
    end

    assert_predicate @queue, :exhausted?
  end

  def test_workers_register
    assert_equal 1, @redis.scard(('build:42:workers'))
    worker(2)
    assert_equal 2, @redis.scard(('build:42:workers'))
  end

  def test_timeout_warning
    begin
      threads = 2.times.map do |i|
        Thread.new do
          queue = worker(i, tests: [TEST_LIST.first], build_id: '24')
          queue.poll do |test|
            sleep 1 # timeout
            queue.acknowledge(test.queue_entry)
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

  def test_streaming_waits_for_batches
    leader = worker(1, populate: false, lazy_load_streaming_timeout: 2, queue_init_timeout: 2, build_id: 'streaming')
    consumer = worker(2, populate: false, lazy_load_streaming_timeout: 2, queue_init_timeout: 2, build_id: 'streaming')
    consumer.entry_resolver = ->(entry) { entry }

    tests = [
      EntryTest.new('ATest#test_foo', CI::Queue::QueueEntry.format('ATest#test_foo', '/tmp/a_test.rb')),
      EntryTest.new('ATest#test_bar', CI::Queue::QueueEntry.format('ATest#test_bar', '/tmp/a_test.rb')),
    ]

    streamed = Enumerator.new do |yielder|
      sleep 0.2
      tests.each { |test| yielder << test }
    end

    leader_thread = Thread.new do
      leader.stream_populate(streamed, random: Random.new(0), batch_size: 1)
    end

    timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      status = @redis.get(leader.send(:key, 'master-status'))
      break if status == 'streaming' || status == 'ready'
      raise "streaming status not set" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > timeout_at
      sleep 0.01
    end

    consumed = []
    consumer_thread = Thread.new do
      consumer.poll do |entry|
        consumed << entry
        consumer.acknowledge(entry)
      end
    end

    sleep 0.05

    leader_thread.join
    consumer_thread.join(2)

    assert_equal tests.map(&:queue_entry).sort, consumed.sort
    assert_predicate consumer, :exhausted?
  end

  def test_reserve_lost_ignores_processed_entry_with_path
    queue = worker(1, populate: false)
    entry = CI::Queue::QueueEntry.format('ATest#test_foo', '/tmp/a_test.rb')

    @redis.zadd(queue.send(:key, 'running'), 0, entry)
    @redis.sadd(queue.send(:key, 'processed'), entry)
    @redis.hset(queue.send(:key, 'owners'), entry, queue.send(:key, 'worker', queue.config.worker_id, 'queue'))

    lost = queue.send(:try_to_reserve_lost_test)
    assert_nil lost
  end

  def test_streaming_timeout_raises_lost_master
    queue = worker(1, populate: false, lazy_load_streaming_timeout: 1, queue_init_timeout: 1)
    @redis.set(queue.send(:key, 'master-status'), 'streaming')
    @redis.set(queue.send(:key, 'streaming-updated-at'), CI::Queue.time_now.to_f - 5)

    assert_raises(CI::Queue::Redis::LostMaster) do
      queue.poll { |_entry| }
    end
  end

  def test_reserve_defers_own_requeued_test_once
    queue = worker(1, populate: false, build_id: 'self-requeue-script')
    queue.send(:register)
    entry = CI::Queue::QueueEntry.format('ATest#test_foo', '/tmp/a_test.rb')
    queue_key = queue.send(:key, 'queue')
    requeued_by_key = queue.send(:key, 'requeued-by')
    worker_queue_key = queue.send(:key, 'worker', queue.config.worker_id, 'queue')
    workers_key = queue.send(:key, 'workers')

    @redis.lpush(queue_key, entry)
    @redis.hset(requeued_by_key, entry, worker_queue_key)
    @redis.sadd(workers_key, '2')

    first_try = queue.send(:try_to_reserve_test)
    assert_nil first_try
    assert_equal [entry], @redis.lrange(queue_key, 0, -1)
    assert_nil @redis.hget(requeued_by_key, entry)

    second_try = queue.send(:try_to_reserve_test)
    assert_equal entry, second_try[0]
  end

  def test_heartbeat_only_checks_lease
    queue = worker(1, populate: false)
    entry = CI::Queue::QueueEntry.format('ATest#test_foo', '/tmp/a_test.rb')
    lease = "42"

    # Set up: entry is in running with a matching lease
    @redis.zadd(queue.send(:key, 'running'), 0, entry)
    @redis.hset(queue.send(:key, 'leases'), entry, lease)

    # Heartbeat with matching lease should succeed (even if processed)
    @redis.sadd(queue.send(:key, 'processed'), entry)
    result = queue.send(
      :eval_script,
      :heartbeat,
      keys: [queue.send(:key, 'running'), queue.send(:key, 'leases')],
      argv: [CI::Queue.time_now.to_f, entry, lease],
    )
    assert_equal 0, result # zadd returns 0 for update (not new)

    # Heartbeat with wrong lease should be no-op
    result = queue.send(
      :eval_script,
      :heartbeat,
      keys: [queue.send(:key, 'running'), queue.send(:key, 'leases')],
      argv: [CI::Queue.time_now.to_f, entry, "wrong-lease"],
    )
    assert_nil result
  end

  def test_resolve_entry_falls_back_to_resolver
    queue = worker(1, populate: false)
    queue.instance_variable_set(:@index, { 'ATest#test_foo' => :ok })
    queue.entry_resolver = ->(entry) { "resolved:#{entry}" }

    missing_entry = CI::Queue::QueueEntry.format('MissingTest#test_bar', '/tmp/missing.rb')
    resolved = queue.send(:resolve_entry, missing_entry)

    assert_equal "resolved:#{missing_entry}", resolved
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
              queue.acknowledge(test.queue_entry)
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

  def test_first_reserve_at_is_set_on_first_reserve
    queue = worker(1)
    assert_nil queue.first_reserve_at

    queue.poll do |_test|
      assert queue.first_reserve_at, "first_reserve_at should be set after first reserve"
      break
    end
  end

  def test_first_reserve_at_does_not_change_on_subsequent_reserves
    queue = worker(1)
    first_value = nil
    count = 0

    queue.poll do |_test|
      first_value ||= queue.first_reserve_at
      assert_equal first_value, queue.first_reserve_at
      count += 1
      break if count >= 3
    end

    assert_operator count, :>=, 2, "Should have reserved multiple tests"
  end

  def test_record_and_read_worker_profiles
    queue = worker(1)
    profile = {
      'worker_id' => '1',
      'mode' => 'lazy',
      'role' => 'leader',
      'total_wall_clock' => 12.34,
      'time_to_first_test' => 1.23,
      'memory_rss_kb' => 512_000,
    }

    queue.build.record_worker_profile(profile)

    profiles = queue.build.worker_profiles
    assert_equal 1, profiles.size
    assert_equal profile, profiles['1']
  end

  def test_worker_profiles_aggregates_multiple_workers
    q1 = worker(1)
    q2 = worker(2)

    q1.build.record_worker_profile({ 'worker_id' => '1', 'role' => 'leader' })
    q2.build.record_worker_profile({ 'worker_id' => '2', 'role' => 'non-leader' })

    profiles = q1.build.worker_profiles
    assert_equal 2, profiles.size
    assert_equal 'leader', profiles['1']['role']
    assert_equal 'non-leader', profiles['2']['role']
  end

  def test_worker_does_not_pick_up_its_own_requeued_test_when_others_are_available
    @redis.flushdb

    test_list = TEST_LIST.first(3)
    w1 = worker(1, tests: test_list, build_id: 'self-requeue', timeout: 10, max_requeues: 1, requeue_tolerance: 1.0)
    w2 = worker(2, populate: false, build_id: 'self-requeue', timeout: 10, max_requeues: 1, requeue_tolerance: 1.0)
    w3 = worker(3, populate: false, build_id: 'self-requeue', timeout: 10, max_requeues: 1, requeue_tolerance: 1.0)
    w2.send(:register)
    w3.send(:register)

    id_for = ->(test) { test.respond_to?(:id) ? test.id : CI::Queue::QueueEntry.test_id(test) }
    entry_for = ->(test) { test.respond_to?(:queue_entry) ? test.queue_entry : test }

    requeued_test_id = nil
    picked_up_requeue = {}
    worker_two_reserved = false
    worker_three_reserved = false
    release_other_workers = false

    mon = Monitor.new
    cond = mon.new_cond

    threads = [
      Thread.new do
        w2.poll do |test|
          test_id = id_for.call(test)
          mon.synchronize do
            worker_two_reserved = true
            picked_up_requeue['2'] = true if test_id == requeued_test_id
            cond.broadcast
            cond.wait_until { release_other_workers }
          end
          w2.acknowledge(entry_for.call(test))
        end
      end,
      Thread.new do
        w3.poll do |test|
          test_id = id_for.call(test)
          mon.synchronize do
            worker_three_reserved = true
            picked_up_requeue['3'] = true if test_id == requeued_test_id
            cond.broadcast
            cond.wait_until { release_other_workers }
          end
          w3.acknowledge(entry_for.call(test))
        end
      end,
    ]

    mon.synchronize do
      cond.wait_until { worker_two_reserved && worker_three_reserved }
    end

    worker_one_picked_its_own_requeue = false
    first_test = true

    w1.poll do |test|
      test_id = id_for.call(test)

      if first_test
        first_test = false
        requeued_test_id = test_id
        w1.report_failure!
        assert_equal true, w1.requeue(entry_for.call(test))
        mon.synchronize do
          release_other_workers = true
          cond.broadcast
        end
      else
        worker_one_picked_its_own_requeue = true if test_id == requeued_test_id
        w1.acknowledge(entry_for.call(test))
      end
    end

    threads.each { |t| t.join(5) }

    assert_equal false, worker_one_picked_its_own_requeue
    assert_equal true, picked_up_requeue.values.any?
  ensure
    threads&.each(&:kill)
  end

  def test_circuit_breaker_does_not_count_requeued_failures
    # Bug: report_failure! was called before the requeue check, so successfully
    # requeued tests incremented the consecutive failure counter. With
    # max_consecutive_failures=3 and 3+ deterministic failures that are all
    # requeued, the circuit breaker fired prematurely and the worker exited,
    # stranding requeued tests in the queue with no worker to process them.
    queue = worker(1, max_requeues: 5, requeue_tolerance: 1.0, max_consecutive_failures: 3)

    # All tests fail (deterministic failures that get requeued)
    tests_processed = poll(queue, false)

    # With 4 tests and max_requeues=5, all tests should be processed multiple
    # times (requeued after each failure). The circuit breaker should NOT fire
    # because requeued failures are transient, not consecutive "real" failures.
    assert tests_processed.size > TEST_LIST.size,
      "Expected tests to be requeued and re-processed, but only #{tests_processed.size} " \
      "tests were processed (circuit breaker likely fired prematurely). " \
      "Circuit breaker open? #{queue.config.circuit_breakers.any?(&:open?)}"
  end

  def test_stolen_test_acknowledge_does_not_remove_running_entry
    @redis.flushdb
    single_test = [TEST_LIST.first]
    queue_a = worker(1, tests: single_test)
    queue_b = worker(2, tests: single_test)

    acquired = false
    stolen = false
    a_acked = false
    monitor = Monitor.new
    condition = monitor.new_cond

    thread = Thread.start do
      monitor.synchronize { condition.wait_until { acquired } }
      queue_b.poll do |test|
        monitor.synchronize do
          stolen = true
          condition.signal
          condition.wait_until { a_acked }
        end
        queue_b.acknowledge(test.queue_entry)
      end
    end

    worker_a_ack_result = nil
    queue_a.poll do |test|
      # Simulate stale heartbeat by setting score to 0 (immediately reclaimable)
      @redis.zadd('build:42:running', 0, test.queue_entry)
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { stolen }
      end
      # Worker B has stolen the test via reserve_lost. Worker A acknowledges.
      # The result (sadd) succeeds, but the running entry must NOT be removed
      # because Worker B still owns it.
      worker_a_ack_result = queue_a.acknowledge(test.queue_entry)
      # Entry should still be in running (Worker B owns it, zrem was skipped)
      assert_operator @redis.zcard('build:42:running'), :>, 0,
        "Running entry must not be removed by non-owner acknowledge"
      monitor.synchronize do
        a_acked = true
        condition.signal
      end
    end

    thread.join(5)

    assert_equal true, worker_a_ack_result, "First finisher's acknowledge should succeed (sadd)"
    assert_predicate queue_a, :exhausted?
  end

  def test_stolen_test_requeue_is_rejected_by_ownership_check
    @redis.flushdb
    single_test = [TEST_LIST.first]
    queue_a = worker(1, tests: single_test, max_requeues: 5, requeue_tolerance: 1.0)
    queue_b = worker(2, tests: single_test, max_requeues: 5, requeue_tolerance: 1.0)

    acquired = false
    stolen = false
    a_requeued = false
    monitor = Monitor.new
    condition = monitor.new_cond

    thread = Thread.start do
      monitor.synchronize { condition.wait_until { acquired } }
      queue_b.poll do |test|
        monitor.synchronize do
          stolen = true
          condition.signal
          condition.wait_until { a_requeued }
        end
        queue_b.acknowledge(test.queue_entry)
      end
    end

    worker_a_requeue_result = nil
    queue_a.poll do |test|
      @redis.zadd('build:42:running', 0, test.queue_entry)
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { stolen }
      end
      # Worker A tries to requeue — should fail (ownership transferred)
      worker_a_requeue_result = queue_a.requeue(test.queue_entry)
      # Entry should still be in running (Worker B owns it)
      assert_operator @redis.zcard('build:42:running'), :>, 0
      monitor.synchronize do
        a_requeued = true
        condition.signal
      end
    end

    thread.join(5)

    assert_equal false, worker_a_requeue_result, "Stale worker's requeue should be rejected"
    assert_predicate queue_a, :exhausted?
  end

  def test_supervisor_not_exhausted_while_stolen_test_in_flight
    @redis.flushdb
    single_test = [TEST_LIST.first]
    queue_a = worker(1, tests: single_test)
    queue_b = worker(2, tests: single_test)
    supervisor = CI::Queue::Redis::Supervisor.new(
      @redis_url,
      CI::Queue::Configuration.new(build_id: '42', timeout: 0.2),
    )

    acquired = false
    stolen = false
    a_acked = false
    monitor = Monitor.new
    condition = monitor.new_cond

    thread = Thread.start do
      monitor.synchronize { condition.wait_until { acquired } }
      queue_b.poll do |test|
        monitor.synchronize do
          stolen = true
          condition.signal
          condition.wait_until { a_acked }
        end
        # Supervisor should NOT be exhausted yet: Worker B still has the test
        refute_predicate supervisor, :exhausted?, "Supervisor should not be exhausted while stolen test is still in-flight"
        queue_b.acknowledge(test.queue_entry)
      end
    end

    queue_a.poll do |test|
      @redis.zadd('build:42:running', 0, test.queue_entry)
      acquired = true
      monitor.synchronize do
        condition.signal
        condition.wait_until { stolen }
      end
      queue_a.acknowledge(test.queue_entry)
      monitor.synchronize do
        a_acked = true
        condition.signal
      end
    end

    thread.join(5)

    # Now supervisor should be exhausted
    assert_predicate supervisor, :exhausted?
  end

  def test_ownership_stress_many_workers_stealing_tests
    # Stress test: multiple workers compete for tests, with frequent lease expiry
    # and stealing. Verifies that exhausted? is never true while tests are in-flight.
    @redis.flushdb
    num_workers = 6
    num_tests = 12
    test_names = num_tests.times.map { |i| "StressTest#test_#{i}" }
    tests = test_names.map { |n| SharedTestCases::TestCase.new(n) }

    queues = num_workers.times.map do |i|
      worker(i + 1, tests: tests, timeout: 0.2, max_requeues: 0, requeue_tolerance: 0, max_consecutive_failures: num_tests)
    end
    supervisor = CI::Queue::Redis::Supervisor.new(
      @redis_url,
      CI::Queue::Configuration.new(build_id: '42', timeout: 0.2),
    )

    mutex = Mutex.new
    all_acknowledged = 0
    errors = []

    threads = queues.map.with_index do |queue, idx|
      Thread.new do
        queue.poll do |test|
          # Randomly simulate stale heartbeat for ~30% of tests
          if idx > 0 && rand < 0.3
            @redis.zadd('build:42:running', 0, test.queue_entry)
            sleep(rand * 0.05) # Tiny jitter to increase contention
          end

          result = queue.acknowledge(test.queue_entry)
          mutex.synchronize { all_acknowledged += 1 } if result
        end
      rescue => e
        mutex.synchronize { errors << "Worker #{idx}: #{e.class}: #{e.message}" }
      end
    end

    threads.each { |t| t.join(10) }
    threads.each { |t| t.kill if t.alive? }

    assert_predicate supervisor, :exhausted?, "All tests should be done. Errors: #{errors.join('; ')}"
    assert_equal num_tests, all_acknowledged, "All #{num_tests} tests should be acknowledged exactly once. Errors: #{errors.join('; ')}"
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
end
