require 'test_helper'

module Integration
  class RedisTest < Minitest::Test
    include OutputHelpers

    def setup
      @redis = Redis.new(db: 7)
      @redis.flushdb
    end

    def test_redis_runner
      output = `ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.map(&:strip).last
      assert_equal '5 tests, 3 assertions, 1 failures, 1 errors, 1 skips', output
      output = `ruby -Itest/fixtures test/fixtures/redis-runner.rb retry`.lines.map(&:strip).last
      assert_equal '5 tests, 3 assertions, 1 failures, 1 errors, 1 skips', output
    end

    def test_redis_reporter
      summary = Minitest::Reporters::RedisReporter::Summary.new(
        redis: @redis,
        build_id: 1,
      )

      output = `ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.map(&:strip).last
      assert_equal '5 tests, 3 assertions, 1 failures, 1 errors, 1 skips', output

      io = StringIO.new
      summary.report(io: io)
      report = strip_heredoc <<-END
        Ran 5 tests, 3 assertions, 1 failures, 1 errors, 1 skips in X.XXs (aggregated).
        FAIL ATest#test_bar
        Expected false to be truthy.
            test/fixtures/dummy_test.rb:9:in `test_bar'

        ERROR BTest#test_bar
        TypeError: String can't be coerced into Fixnum
            test/fixtures/dummy_test.rb:28:in `+'
            test/fixtures/dummy_test.rb:28:in `test_bar'

      END
      assert_equal report, freeze_timing(decolorize_output(io.tap(&:rewind).read))
    end
  end
end
