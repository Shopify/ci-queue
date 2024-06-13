# frozen_string_literal: true
require 'test_helper'

class CI::Queue::Redis::SupervisorTest < Minitest::Test
  include QueueHelper

  def setup
    @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    @redis = ::Redis.new(url: @redis_url)
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

  def test_wait_for_workers_timeout
    @supervisor = supervisor(timeout: 10, queue_init_timeout: 0.1)
    io = nil
    thread = Thread.start do
      io = capture_io { @supervisor.wait_for_workers }
    end
    thread.wakeup
    worker(1)
    thread.join
    assert_includes io.join, "Aborting, it seems all workers died.\n"
  end

  def test_num_workers
    assert_equal 0, @supervisor.workers_count
    worker(1)
    assert_equal 1, @supervisor.workers_count
  end

  private

  def worker(id)
    CI::Queue::Redis.new(
      @redis_url,
      CI::Queue::Configuration.new(
        build_id: '42',
        worker_id: id.to_s,
        timeout: 0.2,
      ),
    ).populate(SharedQueueAssertions::TEST_LIST)
  end

  def supervisor(timeout: 30, queue_init_timeout: nil)
    CI::Queue::Redis::Supervisor.new(
      @redis_url,
      CI::Queue::Configuration.new(
        build_id: '42',
        timeout: timeout,
        queue_init_timeout: queue_init_timeout
      ),
    )
  end
end
