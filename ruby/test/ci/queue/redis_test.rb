# frozen_string_literal: true
require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
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
    test_order = poll(@queue)
    retry_queue = @queue.retry_queue
    populate(retry_queue)
    retry_test_order = poll(retry_queue)
    assert_equal [], retry_test_order
  end

  def test_retry_queue_with_all_tests_passing
    test_order = poll(@queue)
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
          assert_equal true, second_queue.acknowledge(test)
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
        assert_equal false, @queue.acknowledge(test)
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
            queue.acknowledge(test)
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
              queue.acknowledge(test)
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
