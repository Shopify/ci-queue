require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis = ::Redis.new(db: 7)
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

    thread = Thread.start do
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

    assert_equal [TEST_LIST.first], @queue.retry_queue.to_a
    assert_equal TEST_LIST.sort, second_queue.retry_queue.to_a.sort
  end

  private

  def worker(id, **args)
    CI::Queue::Redis.new(
      TEST_LIST.dup,
      redis: @redis,
      build_id: '42',
      worker_id: id.to_s,
      timeout: 0.2,
      **args,
    )
  end
end
