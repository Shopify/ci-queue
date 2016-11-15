require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis = ::Redis.new(db: 7)
    @redis.flushdb
    @queue = worker(1)
  end

  def test_retry_queue
    test_order = @queue.to_enum(:poll).to_a
    assert_equal test_order, @queue.retry_queue.to_enum(:poll).to_a
  end

  def test_shutdown
    @queue.poll do
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
    mutex = Mutex.new
    mutex.lock
    thread = Thread.start do
      @queue.poll do
        mutex.synchronize { }
      end
    end

    test_list = TEST_LIST.dup
    first_test = test_list.shift
    test_list << first_test

    assert_equal test_list, worker(2).to_enum(:poll).to_a
    mutex.unlock
    thread.join
    assert_equal [first_test], @queue.retry_queue.to_a
  end

  private

  def worker(id)
    CI::Queue::Redis.new(
      TEST_LIST.dup,
      redis: @redis,
      build_id: '42',
      worker_id: id.to_s,
      timeout: 0.2,
    )
  end
end
