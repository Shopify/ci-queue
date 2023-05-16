# frozen_string_literal: true
require 'test_helper'

module Integration
  class GrindRedisTest < Minitest::Test
    include OutputTestHelpers

    def setup
      @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
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
      timeout = RUBY_ENGINE == "truffleruby" ? 4 : 1

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _, err = capture_subprocess_io do
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
          '--max-duration', timeout.to_s,
          '-Itest',
          'test/dummy_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      # Ensure it respected the timeout.
      assert_match(/reached its timeout of \d+ seconds/, err)

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

      output_lines = normalize(out).strip.lines
      runs_line = output_lines[2]

      refute_match(
        /all tests passed/,
        output_lines[1].to_s,
        "Expected to find failures.  Might need to increase the timeout (was #{timeout}, took #{took})."
      )

      refute_nil(runs_line, "'Runs:' line not found in #{output_lines.inspect}")
      assert_match(/Runs: \d+/, runs_line)

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
        '--track-test-duration',
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
          '--track-test-duration',
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
        '--track-test-duration',
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
          '--track-test-duration',
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
        '--track-test-duration',
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
          '--track-test-duration',
          chdir: 'test/fixtures/',
        )
      end

      refute_empty err
      assert err.include?("--max-test-duration-percentile must be within range (0, 1] (OptionParser::ParseError)")
    end
  end
end
