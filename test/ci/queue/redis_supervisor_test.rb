require 'test_helper'

class CI::Queue::Redis::SupervisorTest < Minitest::Test
  include QueueHelper

  def setup
    @redis = ::Redis.new(db: 7)
    @redis.flushdb
    @supervisor = supervisor
  end

  def test_wait_for_master_timeout
    assert_raises CI::Queue::Redis::LostMaster do
      @supervisor.wait_for_master(timeout: 0.2)
    end
  end

  def test_wait_for_master
    master_found = false
    thread = Thread.start do
      master_found = @supervisor.wait_for_master
    end
    thread.wakeup
    worker(1)
    thread.join
    assert_equal true, master_found
  end

  def test_wait_for_workers
    workers_done = false
    thread = Thread.start do
      workers_done = @supervisor.wait_for_workers
    end
    thread.wakeup
    poll(worker(1))
    thread.join
    assert_equal true, workers_done
  end

  private

  def worker(id)
    CI::Queue::Redis.new(
      SharedQueueAssertions::TEST_LIST,
      redis: @redis,
      build_id: '42',
      worker_id: id.to_s,
      timeout: 0.2,
    )
  end

  def supervisor
    CI::Queue::Redis::Supervisor.new(
      redis: @redis,
      build_id: '42',
    )
  end
end
