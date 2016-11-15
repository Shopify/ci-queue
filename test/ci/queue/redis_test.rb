require 'test_helper'

class CI::Queue::RedisTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @redis = ::Redis.new(db: 7)
    @redis.flushdb
    @queue = CI::Queue::Redis.new(
      TEST_LIST.dup,
      redis: @redis,
      build_id: '42',
      worker_id: '1',
      timeout: 2,
    )
  end
end
