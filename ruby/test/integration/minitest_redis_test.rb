# frozen_string_literal: true
require 'test_helper'
require 'tmpdir'
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

    def test_buildkite_output
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
      output = normalize(out.lines.last.strip)
      assert_equal '--- Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', output
    end

    def test_custom_requeue
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
          'test/custom_requeue_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal '--- Ran 3 tests, 0 assertions, 0 failures, 2 errors, 0 skips, 1 requeues in X.XXs', output
    end

    def test_max_test_failed
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '--max-test-failed', '3',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_equal 'This worker is exiting early because too many failed tests were encountered.', err.chomp
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 47 tests, 47 assertions, 3 failures, 0 errors, 0 skips, 44 requeues in X.XXs', output

      # Run the reporter
      exit_code = nil
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--timeout', '1',
          '--max-test-failed', '3',
          chdir: 'test/fixtures/',
        )
      end

      refute_predicate $?, :success?
      assert_empty err
      expected = <<~EXPECTED
        Waiting for workers to complete
        Encountered too many failed tests. Test run was ended early.
        97 tests weren't run.
      EXPECTED
      assert_equal expected.strip, normalize(out.lines[0..4].join.strip)
    end

    def test_circuit_breaker
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '--max-consecutive-failures', '3',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_equal "This worker is exiting early because it encountered too many consecutive test failures, probably because of some corrupted state.\n", err
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 3 tests, 3 assertions, 0 failures, 0 errors, 0 skips, 3 requeues in X.XXs', output
    end

    def test_redis_runner
      out, err = capture_subprocess_io do
        system(
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', output

      out, err = capture_subprocess_io do
        system(
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 6 tests, 4 assertions, 2 failures, 1 errors, 0 skips, 3 requeues in X.XXs', output
    end

    def test_retry_success
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/passing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/passing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal 'All tests were ran already', output
    end

    def test_retry_fails_when_test_run_is_expired
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/passing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      one_day = 60 * 60 * 24
      key = ['build', "1", "created-at"].join(':')
      @redis.set(key, Time.now - one_day)

      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/passing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal "The test run is too old and can't be retried", output
    end

    def test_retry_report
      # Run first worker, failing all tests
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 100 tests, 100 assertions, 100 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Run the reporter
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      expect = 'Ran 100 tests, 100 assertions, 100 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)'
      assert_equal expect, normalize(out.strip.lines[1].strip)

      # Simulate another worker successfuly retrying all errors (very hard to reproduce properly)
      queue_config = CI::Queue::Configuration.new(
        timeout: 1,
        build_id: '1',
        worker_id: '2',
      )
      queue = CI::Queue.from_uri(@redis_url, queue_config)
      error_reports = queue.build.error_reports
      assert_equal 100, error_reports.size

      error_reports.keys.each_with_index do |test_id, index|
        queue.build.record_success(test_id.dup, stats: {
          'assertions' => index + 1,
          'errors' => 0,
          'failures' => 0,
          'skips' => 0,
          'requeues' => 0,
          'total_time' => index + 1,
        })
      end

      # Retry first worker, bailing out
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out.lines.last.strip)
      assert_equal 'All tests were ran already', output

      # Re-run the reporter
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      expect = 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)'
      assert_equal expect, normalize(out.strip.lines[1].strip)
    end

    def test_down_redis
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', 'redis://localhost:1337',
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 0 tests, 0 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output
    end

    def test_test_data_reporter
      out, err = capture_subprocess_io do
        system(
          {'CI_QUEUE_FLAKY_TESTS' => 'test/ci_queue_flaky_tests_list.txt'},
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--namespace', 'foo',
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 9 tests, 6 assertions, 1 failures, 1 errors, 1 skips, 2 requeues in X.XXs', output

      content = File.read(@test_data_path)
      failures = JSON.parse(content, symbolize_names: true)
                     .sort_by { |h| "#{h[:test_id]}##{h[:test_index]}" }

      assert_equal 'foo', failures[0][:namespace]
      assert_equal 'ATest#test_bar', failures[0][:test_id]
      assert_equal 'test_bar', failures[0][:test_name]
      assert_equal 'ATest', failures[0][:test_suite]
      assert_equal 'failure', failures[0][:test_result]
      assert_equal true, failures[0][:test_retried]
      assert_equal false, failures[0][:test_result_ignored]
      assert_equal 1, failures[0][:test_assertions]
      assert_equal 'test/dummy_test.rb', failures[0][:test_file_path]
      assert_equal 9, failures[0][:test_file_line_number]
      assert_equal 'Minitest::Assertion', failures[0][:error_class]
      assert_equal 'Expected false to be truthy.', failures[0][:error_message]
      assert_equal 'test/dummy_test.rb', failures[0][:error_file_path]
      assert_equal 10, failures[0][:error_file_number]

      assert_equal 'foo', failures[1][:namespace]
      assert_equal 'ATest#test_bar', failures[1][:test_id]
      assert_equal 'test_bar', failures[1][:test_name]
      assert_equal 'ATest', failures[1][:test_suite]
      assert_equal 'failure', failures[1][:test_result]
      assert_equal false, failures[1][:test_result_ignored]
      assert_equal false, failures[1][:test_retried]
      assert_equal 1, failures[1][:test_assertions]
      assert_equal 'test/dummy_test.rb', failures[1][:test_file_path]
      assert_equal 9, failures[1][:test_file_line_number]
      assert_equal 'Minitest::Assertion', failures[1][:error_class]
      assert_equal 'Expected false to be truthy.', failures[1][:error_message]
      assert_equal 'test/dummy_test.rb', failures[1][:error_file_path]
      assert_equal 10, failures[1][:error_file_number]

      assert failures[0][:test_index] < failures[1][:test_index]

      assert_equal 'ATest#test_flaky', failures[2][:test_id]
      assert_equal 'skipped', failures[2][:test_result]
      assert_equal false, failures[2][:test_retried]
      assert_equal true, failures[2][:test_result_ignored]
      assert_equal 1, failures[2][:test_assertions]
      assert_equal 'test/dummy_test.rb', failures[2][:test_file_path]
      assert_equal 13, failures[2][:test_file_line_number]
      assert_equal 'Minitest::Assertion', failures[2][:error_class]
      assert_equal 18, failures[2][:error_file_number]

      assert_equal 'ATest#test_flaky_passes', failures[4][:test_id]
      assert_equal 'success', failures[4][:test_result]
    end

    def test_test_data_time_reporter
      start_time = Time.now
      travel_to(start_time) do
        capture_subprocess_io do
          system(
            @exe, 'run',
            '--queue', @redis_url,
            '--seed', 'foobar',
            '--namespace', 'foo',
            '--build', '1',
            '--worker', '1',
            '--timeout', '10',
            '-Itest',
            'test/time_test.rb',
            chdir: 'test/fixtures/',
          )
        end
      end
      end_time = Time.now

      content = File.read(@test_data_path)
      failure = JSON.parse(content, symbolize_names: true)
                    .sort_by { |h| "#{h[:test_id]}##{h[:test_index]}" }
                    .first

      assert_in_delta start_time.to_i, failure[:test_start_timestamp], 5
      assert_in_delta end_time.to_i, failure[:test_finish_timestamp], 5
      assert failure[:test_finish_timestamp] > failure[:test_start_timestamp]
    end

    def test_junit_reporter
      out, err = capture_subprocess_io do
        system(
          {'CI_QUEUE_FLAKY_TESTS' => 'test/ci_queue_flaky_tests_list.txt'},
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 9 tests, 6 assertions, 1 failures, 1 errors, 1 skips, 2 requeues in X.XXs', output

      assert_equal <<~XML, normalize_xml(File.read(@junit_path))
        <?xml version="1.1" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="ATest" filepath="test/dummy_test.rb" skipped="5" failures="1" errors="0" tests="6" assertions="5" time="X.XX">
            <testcase name="test_foo" classname="ATest" assertions="0" time="X.XX" flaky_test="false" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_foo\" lineno="5">
              <skipped type="Minitest::Skip"/>
            </testcase>
            <testcase name="test_bar" classname="ATest" assertions="1" time="X.XX" flaky_test="false" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_bar\" lineno="5">
              <skipped type="Minitest::Assertion"/>
            </testcase>
            <testcase name="test_flaky" classname="ATest" assertions="1" time="X.XX" flaky_test="true" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky\" lineno="5">
              <failure type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Skipped:
        test_flaky(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </failure>
            </testcase>
            <testcase name="test_flaky_passes" classname="ATest" assertions="1" time="X.XX" flaky_test="true" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky_passes" lineno="5"/>
            <testcase name="test_flaky_fails_retry" classname="ATest" assertions="1" time="X.XX" flaky_test="true" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky_fails_retry" lineno="5">
              <failure type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Skipped:
        test_flaky_fails_retry(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </failure>
            </testcase>
            <testcase name="test_bar" classname="ATest" assertions="1" time="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_bar" lineno="5">
              <failure type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Failure:
        test_bar(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </failure>
            </testcase>
          </testsuite>
          <testsuite name="BTest" filepath="test/dummy_test.rb" skipped="1" failures="0" errors="1" tests="3" assertions="1" time="X.XX">
            <testcase name="test_bar" classname="BTest" assertions="0" time="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_bar" lineno="36">
              <skipped type="TypeError"/>
            </testcase>
            <testcase name="test_foo" classname="BTest" assertions="1" time="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_foo" lineno="36"/>
            <testcase name="test_bar" classname="BTest" assertions="0" time="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_bar" lineno="36">
              <error type="TypeError" message="TypeError: String can&apos;t be coerced into Integer">
                <![CDATA[
        Failure:
        test_bar(BTest) [test/dummy_test.rb]:
        TypeError: String can't be coerced into Integer
            test/dummy_test.rb:37:in `+'
            test/dummy_test.rb:37:in `test_bar'
        ]]>
              </error>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    def test_redis_reporter_failure_file
      Dir.mktmpdir do |dir|
        failure_file = File.join(dir, 'failure_file.json')

        capture_subprocess_io do
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

        capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--failure-file', failure_file,
            chdir: 'test/fixtures/',
          )
        end

        content = File.read(failure_file)
        failure = JSON.parse(content, symbolize_names: true)
                      .sort_by { |failure_report| failure_report[:test_line] }
                      .first


        ## output and test_file
        expected = {
          test_file: "ci-queue/ruby/test/fixtures/test/dummy_test.rb",
          test_line: 9,
          test_and_module_name: "ATest#test_bar",
          error_class: "Minitest::Assertion",
          test_name: "test_bar",
          test_suite: "ATest",
        }

        assert_includes failure[:test_file], expected[:test_file]
        assert_equal failure[:test_line], expected[:test_line]
        assert_equal failure[:test_suite], expected[:test_suite]
        assert_equal failure[:test_and_module_name], expected[:test_and_module_name]
        assert_equal failure[:test_name], expected[:test_name]
        assert_equal failure[:error_class], expected[:error_class]
      end
    end

    def test_redis_reporter_flaky_tests_file
      Dir.mktmpdir do |dir|
        flaky_tests_file = File.join(dir, 'flaky_tests_file.json')

        capture_subprocess_io do
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

        capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--export-flaky-tests-file', flaky_tests_file,
            chdir: 'test/fixtures/',
          )
        end

        content = File.read(flaky_tests_file)
        flaky_tests = JSON.parse(content)
        assert_includes flaky_tests, "ATest#test_flaky"
      end
    end

    def test_redis_reporter
      # HACK: Simulate a timeout
      config = CI::Queue::Configuration.new(build_id: '1', worker_id: '1', timeout: '1')
      build_record = CI::Queue::Redis::BuildRecord.new(self, ::Redis.new(url: @redis_url), config)
      build_record.record_warning(CI::Queue::Warnings::RESERVED_LOST_TEST, test: 'Atest#test_bar', timeout: 2)

      out, err = capture_subprocess_io do
        system(
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
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', output

      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty err
      output = normalize(out)
      expected_output = <<~END
        Waiting for workers to complete

        [WARNING] Atest#test_bar was picked up by another worker because it didn't complete in the allocated 2 seconds.
        You may want to either optimize this test or bump ci-queue timeout.
        It's also possible that the worker that was processing it was terminated without being able to report back.

        Ran 7 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs (aggregated)

        FAIL ATest#test_bar
        Expected false to be truthy.
            test/dummy_test.rb:10:in `test_bar'

        FAIL ATest#test_flaky_fails_retry
        Expected false to be truthy.
            test/dummy_test.rb:23:in `test_flaky_fails_retry'

        ERROR BTest#test_bar
      END
      assert_includes output, expected_output
    end

    def test_utf8_tests_and_marshal
      out, err = capture_subprocess_io do
        system(
          { 'MARSHAL' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/utf8_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      output = normalize(out)
      assert_equal <<~END, output
        Ran 1 tests, 1 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs
      END
    end

    private

    def normalize_xml(output)
      freeze_xml_timing(rewrite_paths(output))
    end
  end
end
