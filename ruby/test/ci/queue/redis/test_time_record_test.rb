# frozen_string_literal: true
require 'test_helper'

class CI::Queue::Redis::TestTimeRecordTest < Minitest::Test
  def setup
    redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
    redis = Redis.new(url: redis_url)
    redis.flushdb

    config = CI::Queue::Configuration.new(
      timeout: 0.2,
      build_id: '42',
      worker_id: '1',
      max_requeues: 1,
      requeue_tolerance: 0.1,
      max_consecutive_failures: 10,
    )
    @test_time_record = CI::Queue::Redis::TestTimeRecord.new(redis_url, config)
  end

  def test_fetch
    @test_time_record.record('ATest#test_sucess', 0.1)
    @test_time_record.record('ATest#test_sucess', 0.2)
    record = @test_time_record.fetch
    assert_equal 1, record.length
    assert_equal [0.2, 0.1], record['ATest#test_sucess']
  end
end
