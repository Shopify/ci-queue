require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis = ::Redis.new(db: 7, host: ENV.fetch('REDIS_HOST', nil))
    @redis.flushdb
    @queue = worker(1, max_requeues: 1, requeue_tolerance: 0.1)
  end

  def test_requeue # redefine the shared one
    previous_offset = CI::Queue::Redis.requeue_offset
    CI::Queue::Redis.requeue_offset = 2
    failed_once = false
    test_order = poll(@queue, ->(test) {
      if test == TEST_LIST.last && !failed_once
        failed_once = true
        false
      else
        true
      end
    })

    expected_order = TEST_LIST.dup
    expected_order.insert(-CI::Queue::Redis.requeue_offset, TEST_LIST.last)

    assert_equal expected_order, test_order
  ensure
    CI::Queue::Redis.requeue_offset = previous_offset
  end

  def test_retry_queue
    assert_equal poll(@queue), poll(@queue.retry_queue)
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

    assert_predicate @queue, :empty?
    assert_equal [TEST_LIST.first], @queue.retry_queue.to_a
    assert_equal TEST_LIST.sort, second_queue.retry_queue.to_a.sort
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

    assert_predicate @queue, :empty?
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

    assert_predicate @queue, :empty?
  end

  def test_workers_register
    assert_equal 1, @redis.scard(('build:42:workers'))
    worker(2)
    assert_equal 2, @redis.scard(('build:42:workers'))
  end

  def test_continuously_timing_out_tests
    3.times do
      @redis.flushdb
      begin
        threads = 2.times.map do |i|
          Thread.new do
            queue = worker(i, tests: %w(a), build_id: '24')
            queue.poll do |test|
              sleep 1 # timeout
              queue.acknowledge(test)
            end
          end
        end

        threads.each { |t| t.join(3) }
        threads.each { |t| refute_predicate t, :alive? }

        assert_predicate @queue, :empty?
      ensure
        threads.each(&:kill)
      end
    end
  end

  private

  def worker(id, **args)
    test_list = args.delete(:tests) || TEST_LIST.dup
    CI::Queue::Redis.new(
      test_list,
      redis: @redis,
      build_id: '42',
      worker_id: id.to_s,
      timeout: 0.2,
      **args,
    )
  end
end
