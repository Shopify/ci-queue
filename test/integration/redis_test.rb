require 'test_helper'

module Integration
  class RedisTest < Minitest::Test
    def setup
      @redis = Redis.new(db: 7)
      @redis.flushdb
    end

    def test_redis_runner
      output = `ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.map(&:strip).last
      assert_equal '4 runs, 0 assertions, 0 failures, 0 errors, 0 skips', output
      output = `ruby -Itest/fixtures test/fixtures/redis-runner.rb retry`.lines.map(&:strip).last
      assert_equal '4 runs, 0 assertions, 0 failures, 0 errors, 0 skips', output
    end
  end
end
