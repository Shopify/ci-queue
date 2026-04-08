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

  def test_wait_for_workers_waits_for_retry_workers_to_clear_failures
    # Simulate a rebuild: queue is already exhausted from the original run
    poll(worker(1))

    # Inject an unresolved failure into error-reports (as if the original run
    # recorded a failure but the retry worker hasn't re-run it yet)
    entry = CI::Queue::QueueEntry.format("FakeTest#test_failure", "/tmp/fake_test.rb")
    @redis.hset("build:42:error-reports", entry, "{}")

    sup = supervisor(timeout: 2, inactive_workers_timeout: 2)

    with_retry_env do
      # Simulate a retry worker clearing the failure after a short delay
      thread = Thread.start do
        sleep 0.5
        @redis.hdel("build:42:error-reports", entry)
      end

      result = sup.wait_for_workers
      thread.join

      assert_equal true, result
      assert @redis.hkeys("build:42:error-reports").empty?,
        "error-reports should be empty after retry worker cleared the failure"
    end
  end

  def test_wait_for_workers_does_not_wait_on_non_retry
    # Same setup as above but WITHOUT retry env set
    poll(worker(1))

    entry = CI::Queue::QueueEntry.format("FakeTest#test_failure", "/tmp/fake_test.rb")
    @redis.hset("build:42:error-reports", entry, "{}")

    sup = supervisor(timeout: 30, inactive_workers_timeout: 30)

    started_at = CI::Queue.time_now
    result = sup.wait_for_workers
    elapsed = CI::Queue.time_now - started_at

    assert_equal true, result
    assert_operator elapsed, :<, 2.0, "should return immediately without the retry wait"
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

  def supervisor(timeout: 30, queue_init_timeout: nil, inactive_workers_timeout: nil)
    CI::Queue::Redis::Supervisor.new(
      @redis_url,
      CI::Queue::Configuration.new(
        build_id: '42',
        timeout: timeout,
        queue_init_timeout: queue_init_timeout,
        inactive_workers_timeout: inactive_workers_timeout,
      ),
    )
  end

  def with_retry_env
    original = ENV['BUILDKITE_RETRY_COUNT']
    ENV['BUILDKITE_RETRY_COUNT'] = '1'
    yield
  ensure
    if original.nil?
      ENV.delete('BUILDKITE_RETRY_COUNT')
    else
      ENV['BUILDKITE_RETRY_COUNT'] = original
    end
  end
end
