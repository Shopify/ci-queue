# frozen_string_literal: true
require 'test_helper'
require 'tmpdir'
require 'active_support'
require 'active_support/testing/time_helpers'

module Integration
  class MinitestRedisTest < Minitest::Test
    include OutputTestHelpers
    include ActiveSupport::Testing::TimeHelpers

    def setup
      @junit_path = File.expand_path('../../fixtures/log/junit.xml', __FILE__)
      File.delete(@junit_path) if File.exist?(@junit_path)
      @test_data_path = File.expand_path('../../fixtures/log/test_data.json', __FILE__)
      File.delete(@test_data_path) if File.exist?(@test_data_path)
      @order_path = File.expand_path('../../fixtures/log/test_order.log', __FILE__)
      File.delete(@order_path) if File.exist?(@order_path)

      @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
      @redis = Redis.new(url: @redis_url)
      @redis.flushdb
      @exe = File.expand_path('../../../exe/minitest-queue', __FILE__)
    end

    def test_default_reporter
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/dummy_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      assert_match(/Expected false to be truthy/, normalize(out)) # failure output
      result = normalize(out.lines.last.strip)
      puts out.lines.last.strip
      assert_equal '--- Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', result
    end
    private

    def normalize_xml(output)
      freeze_xml_timing(rewrite_paths(output))
    end
  end
end
