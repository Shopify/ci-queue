require 'test_helper'

module Integration
  class RedisTest < Minitest::Test
    include OutputHelpers

    def setup
      @redis = Redis.new(db: 7, host: ENV.fetch('REDIS_HOST', nil))
      @redis.flushdb
    end

    def test_redis_runner
      output = normalize(`ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.last.strip)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output
      output = normalize(`ruby -Itest/fixtures test/fixtures/redis-runner.rb retry`.lines.map(&:strip).last)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output
    end

    def test_down_redis
      previous_redis_host = ENV['REDIS_HOST']
      ENV['REDIS_HOST'] = 'example.com'
      output = normalize(`ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.last.strip)
      assert_equal 'Ran 0 tests, 0 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output
    ensure
      ENV['REDIS_HOST'] = previous_redis_host
    end

    def test_redis_reporter
      summary = Minitest::Reporters::RedisReporter::Summary.new(
        redis: @redis,
        build_id: 1,
      )

      output = normalize(`ruby -Itest/fixtures test/fixtures/redis-runner.rb`.lines.last.strip)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output

      io = StringIO.new
      summary.report(io: io)
      report = strip_heredoc <<-END
        Ran 5 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs (aggregated)
        FAIL ATest#test_bar
        Expected false to be truthy.
            test/fixtures/dummy_test.rb:9:in `test_bar'

        ERROR BTest#test_bar
        TypeError: String can't be coerced into Fixnum
            test/fixtures/dummy_test.rb:28:in `+'
            test/fixtures/dummy_test.rb:28:in `test_bar'

      END
      assert_equal report, normalize(io.tap(&:rewind).read)
    end

    private
    
    def normalize(output)
      freeze_timing(decolorize_output(output))
    end
  end
end
