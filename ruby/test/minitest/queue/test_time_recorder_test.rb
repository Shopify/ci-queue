# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class TestTimeRecorderTest < Minitest::Test
    def setup
      redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
      redis = Redis.new(url: redis_url)
      redis.flushdb

      config ||= CI::Queue::Configuration.new(
        timeout: 0.2,
        build_id: '42',
        worker_id: '1',
        max_requeues: 1,
        requeue_tolerance: 0.1,
        max_consecutive_failures: 10,
      )
      @test_time_record = CI::Queue::Redis::TestTimeRecord.new(redis_url, config)
      @test_time_recorder = TestTimeRecorder.new(build: @test_time_record)
    end

    def test_record_when_test_pass
      test = MiniTest::Mock.new
      test.expect(:passed?, true)
      test.expect(:name, 'some test')
      test.expect(:time, 0.1) # in seconds
      @test_time_recorder.record(test)

      record = @test_time_record.fetch
      assert_equal 1, record.length
      assert_equal [100], record['some test'] # in milliseconds
    end

    def test_record_do_nothing_when_test_failed
      test = MiniTest::Mock.new
      test.expect(:passed?, false)
      @test_time_recorder.record(test)

      record = @test_time_record.fetch
      assert_empty record
    end
  end
end
