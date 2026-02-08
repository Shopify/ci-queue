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

  def test_streaming_waits_for_batches
    leader = worker(1, populate: false, streaming_timeout: 2, queue_init_timeout: 2, build_id: 'streaming')
    consumer = worker(2, populate: false, streaming_timeout: 2, queue_init_timeout: 2, build_id: 'streaming')
    consumer.entry_resolver = ->(entry) { entry }

    tests = [
      EntryTest.new('ATest#test_foo', 'ATest#test_foo|/tmp/a_test.rb'),
      EntryTest.new('ATest#test_bar', 'ATest#test_bar|/tmp/a_test.rb'),
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
    entry = 'ATest#test_foo|/tmp/a_test.rb'
    test_id = 'ATest#test_foo'

    @redis.zadd(queue.send(:key, 'running'), 0, entry)
    @redis.sadd(queue.send(:key, 'completed'), test_id)
    @redis.hset(queue.send(:key, 'owners'), entry, queue.send(:key, 'worker', queue.config.worker_id, 'queue'))

    lost = queue.send(:try_to_reserve_lost_test)
    assert_nil lost
  end

  def test_streaming_timeout_raises_lost_master
    queue = worker(1, populate: false, streaming_timeout: 1, queue_init_timeout: 1)
    @redis.set(queue.send(:key, 'master-status'), 'streaming')
    @redis.set(queue.send(:key, 'streaming-updated-at'), CI::Queue.time_now.to_f - 5)

    assert_raises(CI::Queue::Redis::LostMaster) do
      queue.poll { |_entry| }
    end
  end

  def test_heartbeat_uses_test_id_for_processed_check
    queue = worker(1, populate: false)
    entry = 'ATest#test_foo|/tmp/a_test.rb'
    test_id = 'ATest#test_foo'

    @redis.sadd(queue.send(:key, 'processed'), test_id)

    result = queue.send(
      :eval_script,
      :heartbeat,
      keys: [
        queue.send(:key, 'running'),
        queue.send(:key, 'processed'),
        queue.send(:key, 'owners'),
        queue.send(:key, 'worker', queue.config.worker_id, 'queue'),
      ],
      argv: [CI::Queue.time_now.to_f, entry],
    )

    assert_nil result
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
