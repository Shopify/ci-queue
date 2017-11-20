require 'test_helper'

module Integration
  class RedisTest < Minitest::Test
    include OutputHelpers

    def setup
      @redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
      @redis = Redis.new(url: @redis_url)
      @redis.flushdb
    end

    def test_redis_runner
      output = normalize(`
        exe/minitest-queue \
        --url '#{@redis_url}' \
        --seed foobar \
        --build 1 \
        --worker 1 \
        --timeout 1 \
        --max-requeues 1  \
        --requeue-tolerance 1  \
        -Itest/fixtures \
        test/fixtures/dummy_test.rb \
      `.lines.last.strip)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output

      output = normalize(`
        exe/minitest-queue \
        --retry \\
        --url '#{@redis_url}' \
        --seed foobar \
        --build 1 \
        --worker 1 \
        --timeout 1 \
        --max-requeues 1  \
        --requeue-tolerance 1  \
        -Itest/fixtures \
        test/fixtures/dummy_test.rb \
      `.lines.last.strip)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output
    end

    def test_down_redis
      output = normalize(`
        exe/minitest-queue \
        --url 'redis://localhost:1337/1' \
        --seed foobar \
        --build 1 \
        --worker 1 \
        --timeout 1 \
        --max-requeues 1  \
        --requeue-tolerance 1  \
        -Itest/fixtures \
        test/fixtures/dummy_test.rb \
      `.lines.last.strip)
      assert_equal 'Ran 0 tests, 0 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output
    end

    def test_redis_reporter
      summary = Minitest::Reporters::RedisReporter::Summary.new(
        redis: @redis,
        build_id: '1',
      )

      output = normalize(`
        exe/minitest-queue \
        --url '#{@redis_url}' \
        --seed foobar \
        --build 1 \
        --worker 1 \
        --timeout 1 \
        --max-requeues 1  \
        --requeue-tolerance 1  \
        -Itest/fixtures \
        test/fixtures/dummy_test.rb \
      `.lines.last.strip)
      assert_equal 'Ran 8 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs', output

      io = StringIO.new
      summary.report(io: io)
      output = normalize(io.tap(&:rewind).read)

      assert_equal strip_heredoc(<<-END), output
        Ran 5 tests, 5 assertions, 1 failures, 1 errors, 1 skips, 3 requeues in X.XXs (aggregated)
        FAIL ATest#test_bar
        Expected false to be truthy.
            test/fixtures/dummy_test.rb:9:in `test_bar'

        ERROR BTest#test_bar
        TypeError: String can't be coerced into Fixnum
            test/fixtures/dummy_test.rb:28:in `+'
            test/fixtures/dummy_test.rb:28:in `test_bar'

      END
    end

    private
    
    def normalize(output)
      freeze_timing(decolorize_output(output))
    end
  end
end
