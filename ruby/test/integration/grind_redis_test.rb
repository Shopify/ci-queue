# frozen_string_literal: true
require 'test_helper'

module Integration
  class GrindRedisTest < Minitest::Test
    include OutputTestHelpers

    def setup
      @redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
      @redis = Redis.new(url: @redis_url)
      @redis.flushdb
      @exe = File.expand_path('../../../exe/minitest-queue', __FILE__)
    end

    def test_grind_command_success
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '--grind-list', 'grind_list_success.txt',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip
      expected = <<~EOS
        +++ Results
        all tests passed every time, grinding did not uncover any flakiness
      EOS
      assert_equal expected.strip, output
      assert_empty err
    end

    def test_grind_command_runs_tests
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '--grind-list', 'grind_list.txt',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip
      expected = <<~EOS
        +++ Results
        ATest#test_flaky
        Runs: 10
        Failures: 1
        Flakiness Percentage: 10%
        Errors:
        \tFAIL ATest#test_flaky
        \tExpected false to be truthy.
        \t    test/dummy_test.rb:18:in `test_flaky'
      EOS
      assert_empty err
      assert_equal expected.strip, output
    end

    def test_grind_max_time
      grind_count = 1000000
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', grind_count.to_s,
        '--grind-list', 'grind_list.txt',
        '--max-duration', '1',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip
      runs_line = output.lines[2]
      run_count = runs_line.scan(/\w+/).last.to_i

      assert_empty err
      assert run_count < grind_count
    end

    def test_can_grind_multiple_things
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--grind-list', 'grind_multiples_list.txt',
        '--queue', @redis_url,
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip

      expected = <<~EOS
        +++ Results
        ATest#test_flaky
        Runs: 10
        Failures: 1
        Flakiness Percentage: 10%
        Errors:
        \tFAIL ATest#test_flaky
        \tExpected false to be truthy.
        \t    test/dummy_test.rb:18:in `test_flaky'
        \t

        ATest#test_bar
        Runs: 10
        Failures: 10
        Flakiness Percentage: 100%
        Errors:
        \tFAIL ATest#test_bar
        \tExpected false to be truthy.
        \t    test/dummy_test.rb:10:in `test_bar'
      EOS
      assert_equal expected.strip, output
      assert_empty err
    end

    def test_grind_max_test_duration_passing
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '--grind-list', 'grind_list_success.txt',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          '--max-test-duration', '1000',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip
      expected = <<~EOS
        +++ Results
        all tests passed every time, grinding did not uncover any flakiness
        +++ Test Time Report
        The 50th of test execution time is within 1000.0 milliseconds.
      EOS
      assert_equal expected.strip, output
      assert_empty err
    end

    def test_grind_max_test_duration_failing
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '--grind-list', 'grind_list_success.txt',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          '--max-test-duration', '0.00001',
          chdir: 'test/fixtures/',
        )
      end

      output = normalize(out).strip
      expected = <<~EOS
        +++ Results
        all tests passed every time, grinding did not uncover any flakiness
        +++ Test Time Report
        Detected 1 test(s) over the desired time limit.
        Please make them faster than 1.0e-05ms in the 50th percentile.
        test_flaky_passes:
      EOS
      assert output.start_with?(expected.strip)
      assert_empty err
    end

    def test_grind_max_test_duration_percentile_outside_range
      system(
        { 'BUILDKITE' => '1' },
        @exe, 'grind',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', '1',
        '--worker', '1',
        '--timeout', '1',
        '--grind-count', '10',
        '--grind-list', 'grind_list_success.txt',
        '-Itest',
        'test/dummy_test.rb',
        chdir: 'test/fixtures/',
      )

      _, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1' },
          @exe, 'report_grind',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '5',
          '--max-test-duration', '1000',
          '--max-test-duration-percentile', '1.1',
          chdir: 'test/fixtures/',
        )
      end

      refute_empty err
      assert err.include?("--max-test-duration-percentile must be within range (0, 1] (OptionParser::ParseError)")
    end
  end
end
