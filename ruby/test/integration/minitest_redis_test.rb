# frozen_string_literal: true
require 'test_helper'
require 'tmpdir'
require 'active_support'
require 'active_support/testing/time_helpers'
require 'concurrent/set'

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

      assert_empty filter_deprecation_warnings(err)
      assert_match(/Expected false to be truthy/, normalize(out)) # failure output
      result = normalize(out.lines.last.strip)
      assert_equal '--- Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', result
    end

    def test_lost_test_with_heartbeat_monitor
      _, err = capture_subprocess_io do
        2.times.map do |i|
          Thread.start  do
            system(
              { 'BUILDKITE' => '1' },
              @exe, 'run',
              '--queue', @redis_url,
              '--seed', 'foobar',
              '--build', '1',
              '--worker', i.to_s,
              '--timeout', '1',
              '--max-requeues', '1',
              '--requeue-tolerance', '1',
              '--heartbeat', '5',
              '-Itest',
              'test/lost_test.rb',
              chdir: 'test/fixtures/',
            )
          end
        end.each(&:join)
      end

      assert_empty filter_deprecation_warnings(err)

      Tempfile.open('warnings') do |warnings_file|
        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--warnings-file', warnings_file.path,
            '--heartbeat',
            chdir: 'test/fixtures/',
            )
        end

        assert_empty filter_deprecation_warnings(err)
        result = normalize(out.lines[1].strip)
        # lost_test.rb test_foo has no assertions (only sleep)
        assert_equal "Ran 1 tests, 0 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)", result
        warnings = warnings_file.read.lines.map { |line| JSON.parse(line) }
        # With lease-based heartbeat, the heartbeat keeps the entry alive for the
        # full test duration, so the test is never stolen and no warning is generated.
        assert_equal 0, warnings.size
      end
    end

    def test_lost_test_with_heartbeat_max_duration
      # Start worker 0 first so it claims the test before worker 1 starts polling.
      # Worker 0 heartbeat caps at 0.3s → entry stale at ~t=2 → worker 1 steals at ~t=2.
      # lost_test sleeps 3s, giving a ~1s window for the steal before the test finishes.
      _, err = capture_subprocess_io do
        t0 = Thread.start do
          system(
            { 'BUILDKITE' => '1' },
            @exe, 'run',
            '--queue', @redis_url,
            '--seed', 'foobar',
            '--build', '1',
            '--worker', '0',
            '--timeout', '1',
            '--max-requeues', '1',
            '--requeue-tolerance', '1',
            '--heartbeat', '2',
            '--heartbeat-max-test-duration', '0.3',
            '-Itest',
            'test/lost_test.rb',
            chdir: 'test/fixtures/',
          )
        end

        # Give worker 0 time to claim the test before worker 1 starts polling.
        sleep 0.5

        t1 = Thread.start do
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
            '--heartbeat', '2',
            '--heartbeat-max-test-duration', '0.3',
            '-Itest',
            'test/lost_test.rb',
            chdir: 'test/fixtures/',
          )
        end

        [t0, t1].each(&:join)
      end

      assert_empty filter_deprecation_warnings(err)

      Tempfile.open('warnings') do |warnings_file|
        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--warnings-file', warnings_file.path,
            '--heartbeat',
            chdir: 'test/fixtures/',
          )
        end

        assert_empty filter_deprecation_warnings(err)
        warnings = warnings_file.read.lines.map { |line| JSON.parse(line) }
        # Worker 0's heartbeat caps at 0.3s; the entry goes stale ~2s after the last tick
        # (before lost_test finishes at t=3). Worker 1 steals it, generating a warning.
        assert warnings.size >= 1, "Expected at least 1 RESERVED_LOST_TEST warning, got #{warnings.size}"
      end
    end

    def test_heartbeat_cap_doesnt_affect_fast_tests
      # With cap enabled, fast-passing tests should complete normally with no entries
      # going stale. The heartbeat cap should be a no-op when tests finish quickly.
      _, err = capture_subprocess_io do
        2.times.map do |i|
          Thread.start do
            system(
              { 'BUILDKITE' => '1' },
              @exe, 'run',
              '--queue', @redis_url,
              '--seed', 'foobar',
              '--build', '1',
              '--worker', i.to_s,
              '--timeout', '1',
              '--heartbeat', '5',
              '--heartbeat-max-test-duration', '60',
              '-Itest',
              'test/passing_test.rb',
              chdir: 'test/fixtures/',
            )
          end
        end.each(&:join)
      end

      assert_empty filter_deprecation_warnings(err)

      Tempfile.open('warnings') do |warnings_file|
        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--warnings-file', warnings_file.path,
            '--heartbeat',
            chdir: 'test/fixtures/',
          )
        end

        assert_empty filter_deprecation_warnings(err)
        result = normalize(out.lines[1].strip)
        assert_equal "Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)", result
        warnings = warnings_file.read.lines.map { |line| JSON.parse(line) }
        assert_equal 0, warnings.size, "No tests should be stolen -- heartbeat cap should not have fired"
      end
    end

    def test_lazy_loading_streaming
      out, err = capture_subprocess_io do
        threads = 2.times.map do |i|
          Thread.start do
            system(
              { 'BUILDKITE' => '1' },
              @exe, 'run',
              '--queue', @redis_url,
              '--seed', 'foobar',
              '--build', 'lazy-stream',
              '--worker', i.to_s,
              '--timeout', '1',
              '--lazy-load',
              '--lazy-load-stream-batch-size', '1',
              '--lazy-load-stream-timeout', '5',
              '-Itest',
              'test/passing_test.rb',
              chdir: 'test/fixtures/',
            )
          end
        end
        threads.each(&:join)
      end

      assert_empty filter_deprecation_warnings(err)

      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', 'lazy-stream',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty filter_deprecation_warnings(err)
      result = normalize(out.lines[1].strip)
      assert_equal 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)', result
    end

    # Reproduces the "No leader was elected" bug in lazy-load mode.
    # When using --test-files (no positional args), non-leader workers must still
    # enter queue.poll. Without the fix, non-leaders exit immediately with status 0
    # because minitest's at_exit hook never fires.
    #
    # We verify the fix by checking that BOTH workers processed tests (via their
    # worker queue keys in Redis), not just the leader.
    def test_lazy_loading_with_test_files_option
      build_id = 'lazy-test-files'
      test_files = File.expand_path('../../fixtures/test/passing_test.rb', __FILE__)
      Tempfile.open('test_files_list') do |f|
        f.write(test_files)
        f.flush

        out, err = capture_subprocess_io do
          threads = 2.times.map do |i|
            Thread.start do
              system(
                { 'BUILDKITE' => '1' },
                @exe, 'run',
                '--queue', @redis_url,
                '--seed', 'foobar',
                '--build', build_id,
                '--worker', i.to_s,
                '--timeout', '5',
                '--queue-init-timeout', '10',
                '--lazy-load',
                '--test-files', f.path,
                '--lazy-load-stream-batch-size', '1',
                '--lazy-load-stream-timeout', '10',
                '-Itest',
                chdir: 'test/fixtures/',
              )
            end
          end
          threads.each(&:join)
        end

        assert_empty filter_deprecation_warnings(err)

        # Verify the non-leader actually entered queue.poll and processed tests.
        # The leader may process 0 tests if the non-leader is fast enough to drain
        # the queue before the leader finishes streaming.
        worker_0_count = @redis.llen("build:#{build_id}:worker:0:queue")
        worker_1_count = @redis.llen("build:#{build_id}:worker:1:queue")

        assert_operator worker_0_count + worker_1_count, :>=, 100, "All tests should have been processed"
        assert_operator [worker_0_count, worker_1_count].max, :>, 0, "At least one worker should have processed tests (non-leader likely exited without running minitest if both are 0)"

        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', build_id,
            '--timeout', '5',
            chdir: 'test/fixtures/',
          )
        end

        assert_empty filter_deprecation_warnings(err)
        result = normalize(out.lines[1].strip)
        assert_equal 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)', result
      end
    end

    # Verifies that dynamically generated test methods (defined in runnable_methods,
    # not at class load time) work correctly in lazy-load mode. This catches issues
    # like Shopify's Verdict FLAGS methods not being found on non-leader workers.
    def test_lazy_loading_dynamic_test_methods
      build_id = 'lazy-dynamic'
      test_files = File.expand_path('../../fixtures/test/dynamic_test.rb', __FILE__)
      Tempfile.open('test_files_list') do |f|
        f.write(test_files)
        f.flush

        out, err = capture_subprocess_io do
          threads = 2.times.map do |i|
            Thread.start do
              system(
                { 'BUILDKITE' => '1' },
                @exe, 'run',
                '--queue', @redis_url,
                '--seed', 'foobar',
                '--build', build_id,
                '--worker', i.to_s,
                '--timeout', '5',
                '--queue-init-timeout', '10',
                '--lazy-load',
                '--test-files', f.path,
                '--lazy-load-stream-batch-size', '1',
                '--lazy-load-stream-timeout', '10',
                '-Itest',
                chdir: 'test/fixtures/',
              )
            end
          end
          threads.each(&:join)
        end

        assert_empty filter_deprecation_warnings(err)

        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', build_id,
            '--timeout', '5',
            chdir: 'test/fixtures/',
          )
        end

        assert_empty filter_deprecation_warnings(err)
        # 1 static + 3 dynamic variants = 4 tests
        result = normalize(out.lines[1].strip)
        assert_equal 'Ran 4 tests, 4 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)', result
      end
    end

    def test_worker_profile_in_report
      build_id = 'profile-report'
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'CI_QUEUE_DEBUG' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', build_id,
          '--worker', '0',
          '--timeout', '5',
          '--lazy-load',
          '--lazy-load-stream-batch-size', '10',
          '--lazy-load-stream-timeout', '5',
          '-Itest',
          'test/passing_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty filter_deprecation_warnings(err)

      out, err = capture_subprocess_io do
        system(
          { 'CI_QUEUE_DEBUG' => '1' },
          @exe, 'report',
          '--queue', @redis_url,
          '--build', build_id,
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty filter_deprecation_warnings(err)
      assert_includes out, 'Worker profile summary'
      assert_includes out, 'leader'
      assert_includes out, 'Wall Clock'
    end

    def test_verbose_reporter
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
          '-v',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty filter_deprecation_warnings(err)
      assert_match(/ATest#test_foo \d+\.\d+ = S/, normalize(out)) # verbose test ouptut
      result = normalize(out.lines.last.strip)
      assert_equal '--- Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', result
    end

    def test_debug_log
      Tempfile.open('debug_log') do |log_file|
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
            '--debug-log', log_file.path,
            chdir: 'test/fixtures/',
          )
        end

      assert_includes File.read(log_file.path), 'INFO -- : Finished \'["exists", "build:1:worker:1:queue"]\': 0'
      assert_empty filter_deprecation_warnings(err)
      result = normalize(out.lines.last.strip)
      assert_equal '--- Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', result
      end
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

      assert_empty filter_deprecation_warnings(err)
      assert_match(/^\^{3} \+{3}$/m, normalize(out)) # reopen failed step
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

      assert_empty filter_deprecation_warnings(err)
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
          '--heartbeat', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '--max-test-failed', '3',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      refute_predicate $?, :success?
      assert_equal 1, $?.exitstatus
      assert_equal 'This worker is exiting early because too many failed tests were encountered.', filter_deprecation_warnings(err).chomp
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 47 tests, 47 assertions, 3 failures, 0 errors, 0 skips, 44 requeues in X.XXs', output

      # Run the reporter
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
      assert_equal 44, $?.exitstatus
      assert_empty filter_deprecation_warnings(err)
      expected = <<~EXPECTED
        Waiting for workers to complete
        Requeued 44 tests
      EXPECTED
      assert_equal expected.strip, normalize(out.lines[0..1].join.strip)
      expected = <<~EXPECTED
        Ran 3 tests, 47 assertions, 3 failures, 0 errors, 0 skips, 44 requeues in X.XXs (aggregated)
      EXPECTED
      assert_equal expected.strip, normalize(out.lines[134].strip)
      expected = <<~EXPECTED
        Encountered too many failed tests. Test run was ended early.
      EXPECTED
      assert_equal expected.strip, normalize(out.lines[136].strip)
      expected = <<~EXPECTED
        97 tests weren't run.
      EXPECTED
      assert_equal expected.strip, normalize(out.lines.last.strip)
    end

    def test_all_workers_died
      # Run the reporter
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
      assert_equal 40, $?.exitstatus
      assert_empty filter_deprecation_warnings(err)
      expected = <<~EXPECTED
        Waiting for workers to complete
        No leader was elected. This typically means no worker was able to start. Were there any errors during application boot?
      EXPECTED
      assert_equal expected.strip, normalize(out.lines[0..2].join.strip)
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

      # Requeued failures don't count toward the circuit breaker. The worker
      # processes more tests than the old behavior (which stopped at 3).
      # Exact count depends on queue ordering, but must be > 3.
      output = normalize(out.lines.last.strip)
      ran_count = output.match(/Ran (\d+) tests/)[1].to_i
      assert ran_count > 3,
        "Expected more than 3 tests to run (requeues shouldn't trip breaker), got: #{output}"
    end

    def test_circuit_breaker_without_requeues
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '0',
          '--max-consecutive-failures', '3',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_equal "This worker is exiting early because it encountered too many consecutive test failures, probably because of some corrupted state.\n", filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 3 tests, 3 assertions, 3 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output
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

      assert_empty filter_deprecation_warnings(err)
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

      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'All tests were ran already', output
    end

    def test_automatic_retry
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
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 200 tests, 200 assertions, 100 failures, 0 errors, 0 skips, 100 requeues in X.XXs', output

      out, err = capture_subprocess_io do
        system(
          { "BUILDKITE_RETRY_TYPE" => "automatic" },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          '-Itest',
          'test/failing_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'All tests were ran already', output
    end

    def test_automatic_retry_reruns_failed_tests_so_report_can_succeed
      # Simulate the scenario from the Sam O'Brien / Steph Sachrajda incident:
      # A test fails on the first run (flaky infra timeout). Buildkite auto-retries
      # the step (LSO). The retried worker finds the main queue exhausted and exits 0,
      # making the step green. But error_reports persist in Redis, so the separate
      # "Post Merge Testing Summary" (report command) still fails.
      #
      # Expected fix: automatic retry should re-run failed tests (retry_queue),
      # not silently exit 0 when there are unresolved failures.

      # First run: the flaky test fails (FLAKY_TEST_PASS not set → assert_equal '1', nil fails)
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Buildkite auto-retries the step. The flaky condition is resolved (FLAKY_TEST_PASS=1).
      # BUG: with BUILDKITE_RETRY_TYPE=automatic, manual_retry? returns false, so the runner
      # skips retry_queue and finds the main queue exhausted → exits 0 without re-running
      # the failed test. Error report stays in Redis.
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'automatic', 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      # After the fix, the automatic retry should re-run the failed test and report success.
      # Worker 2 has no per-worker log — must fall back to error-reports.
      assert_match(/Retrying failed tests/, out)

      # The report step runs after all workers complete. After the fix, the failed test
      # passed on automatic retry so error_reports should be empty → report succeeds.
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/0 failures/, normalize(out))
    end

    def test_automatic_retry_report_still_fails_when_test_keeps_failing
      # Inverse of test_automatic_retry_reruns_failed_tests_so_report_can_succeed.
      # When the failing test also fails on automatic retry, the report must still
      # report the failure — we must not incorrectly suppress errors.

      # First run: flaky test fails
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Automatic retry: FLAKY_TEST_PASS still not set → test fails again on retry
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'automatic' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)

      # Report must still fail — the test failed on retry too
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      # Test failed on original run AND on retry — aggregate shows multiple failures.
      # The key invariant: error-reports are non-empty and the report still fails.
      assert_match(/FlakyTest#test_flaky/, out)
      refute_match(/0 failures/, normalize(out))
    end

    def test_rebuild_retries_failed_tests_from_different_worker
      # Simulates a Buildkite rebuild: worker 1 runs and fails a test, then
      # a DIFFERENT worker (worker 2) is spawned in the rebuild with
      # BUILDKITE_RETRY_COUNT=1, BUILDKITE_RETRY_TYPE=manual.
      # Worker 2 has an empty per-worker log — it must fall back to
      # error-reports to find the failed test and retry it.

      # First run: worker 1 runs flaky_test.rb, test_flaky fails
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Rebuild: DIFFERENT worker (--worker 2) retries with manual retry env vars.
      # Worker 2 has no per-worker log for this build — retry_queue must fall back
      # to error-reports to find the failed test.
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual', 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/Retrying failed tests/, out)

      # Report should show 0 failures — the test passed on retry
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/0 failures/, normalize(out))
    end

    def test_rebuild_report_still_fails_when_test_keeps_failing
      # Inverse: different worker retries the failing test but it still fails.
      # Report must still show the failure.

      # First run: worker 1 runs flaky_test.rb, test_flaky fails
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Rebuild: different worker, FLAKY_TEST_PASS NOT set → test fails again
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)

      # Report must still fail — the test failed on retry too
      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/FlakyTest#test_flaky/, out)
      refute_match(/0 failures/, normalize(out))
    end

    def test_same_worker_manual_retry_reruns_failed_tests
      # Same worker retries (per-worker log exists): the fallback to error-reports
      # should NOT be needed — the per-worker log intersection finds the failure directly.

      # First run: worker 1 fails test_flaky
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', output

      # Same worker retries — per-worker log should yield the failed test
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual', 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/Retrying failed tests/, out)

      out, err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/0 failures/, normalize(out))
    end

    def test_rebuild_different_worker_with_no_failures_exits_cleanly
      # Different worker retries but there's nothing in error-reports (no failures).
      # Both per-worker log AND fallback yield empty → should exit cleanly.

      # First run: worker 1, all tests pass (FLAKY_TEST_PASS=1 so no failures)
      out, err = capture_subprocess_io do
        system(
          { 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      # Worker 2 retries with empty per-worker log AND empty error-reports
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual', 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/All tests were ran already/, out)
    end

    def test_report_waits_for_retry_worker_to_clear_failures
      # Simulates the race condition seen in build 900737:
      # - Report step starts (BUILDKITE_RETRY_COUNT=1), sees queue exhausted immediately,
      #   but error-reports still has a failure from the original run.
      # - A retry worker is concurrently running the failed test.
      # - Without the fix, report exits immediately and cancels the retry worker.
      # - With the fix, report waits up to inactive_workers_timeout for
      #   retry workers to clear error-reports before reporting.

      # First run: worker 1 fails a test
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/1 failures/, normalize(out))

      # Start the report concurrently — it should block waiting for retry workers
      report_out = nil
      report_err = nil
      report_thread = Thread.new do
        report_out, report_err = capture_subprocess_io do
          system(
            { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual' },
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--inactive-workers-timeout', '10',
            chdir: 'test/fixtures/',
          )
        end
      end

      # Give the report a moment to start, then run the retry worker which
      # re-runs the failed test and clears error-reports
      sleep 0.3
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE_RETRY_COUNT' => '1', 'BUILDKITE_RETRY_TYPE' => 'manual', 'FLAKY_TEST_PASS' => '1' },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          '-Itest',
          'test/flaky_test.rb',
          chdir: 'test/fixtures/',
        )
      end
      assert_empty filter_deprecation_warnings(err)
      assert_match(/Retrying failed tests/, out)

      report_thread.join(15)
      assert_empty filter_deprecation_warnings(report_err || '')
      assert_match(/0 failures/, normalize(report_out || ''))
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
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

      queue.build.failed_test_entries.each_with_index do |entry, index|
        test_id = CI::Queue::QueueEntry.test_id(entry)
        queue.instance_variable_set(:@reserved_tests, Concurrent::Set.new([test_id]))
        reserved_entries = queue.instance_variable_get(:@reserved_entries) || Concurrent::Map.new
        reserved_entries[test_id] = entry
        queue.instance_variable_set(:@reserved_entries, reserved_entries)
        queue.build.record_success(entry)
        queue.build.record_stats({
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
      expect = 'Ran 100 tests, 100 assertions, 0 failures, 0 errors, 0 skips, 0 requeues in X.XXs (aggregated)'
      assert_equal expect, normalize(out.strip.lines[1].strip)
    end

    def test_down_redis
      out, err = capture_subprocess_io do
        system(
          { "CI_QUEUE_DISABLE_RECONNECT_ATTEMPTS" => "1" },
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
      assert_empty filter_deprecation_warnings(err)
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
      assert_empty filter_deprecation_warnings(err)
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

      start_delta = self.class.truffleruby? ? 15 : 5
      assert_in_delta start_time.to_i, failure[:test_start_timestamp], start_delta, "start time"
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
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      assert_equal 'Ran 9 tests, 6 assertions, 1 failures, 1 errors, 1 skips, 2 requeues in X.XXs', output

      # NOTE: To filter the TypeError backtrace below see test/fixtures/test/backtrace_filters.rb

      assert_equal <<~XML, normalize_xml(File.read(@junit_path))
        <?xml version="1.1" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="ATest" filepath="test/dummy_test.rb" skipped="5" failures="1" errors="0" tests="6" assertions="5" time="X.XX">
            <testcase name="test_foo" classname="ATest" assertions="0" time="X.XX" timestamp="X.XX" flaky_test="false" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_foo\" lineno="5">
              <skipped type="Minitest::Skip" message="Skipped, no message given">
                <![CDATA[
        Skipped:
        test_foo(ATest) [test/dummy_test.rb]:
        Skipped, no message given
        ]]>
              </skipped>
            </testcase>
            <testcase name="test_bar" classname="ATest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="false" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_bar\" lineno="5">
              <skipped type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Skipped:
        test_bar(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </skipped>
            </testcase>
            <testcase name="test_flaky" classname="ATest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="true" run-command=\"bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky\" lineno="5">
              <failure type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Skipped:
        test_flaky(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </failure>
            </testcase>
            <testcase name="test_flaky_passes" classname="ATest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="true" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky_passes" lineno="5"/>
            <testcase name="test_flaky_fails_retry" classname="ATest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="true" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_flaky_fails_retry" lineno="5">
              <failure type="Minitest::Assertion" message="Expected false to be truthy.">
                <![CDATA[
        Skipped:
        test_flaky_fails_retry(ATest) [test/dummy_test.rb]:
        Expected false to be truthy.
        ]]>
              </failure>
            </testcase>
            <testcase name="test_bar" classname="ATest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n ATest\\#test_bar" lineno="5">
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
            <testcase name="test_bar" classname="BTest" assertions="0" time="X.XX" timestamp="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_bar" lineno="36">
              <skipped type="TypeError" message="TypeError: String can&apos;t be coerced into Integer">
                <![CDATA[
        Skipped:
        test_bar(BTest) [test/dummy_test.rb]:
        TypeError: String can't be coerced into Integer
            test/dummy_test.rb:37:in `+'
            test/dummy_test.rb:37:in `test_bar'
        ]]>
              </skipped>
            </testcase>
            <testcase name="test_foo" classname="BTest" assertions="1" time="X.XX" timestamp="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_foo" lineno="36"/>
            <testcase name="test_bar" classname="BTest" assertions="0" time="X.XX" timestamp="X.XX" flaky_test="false" run-command="bundle exec ruby -Ilib:test test/dummy_test.rb -n BTest\\#test_bar" lineno="36">
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

        xml_file = File.join(File.dirname(failure_file), "#{File.basename(failure_file, File.extname(failure_file))}.xml")
        xml_content = File.read(xml_file)
        xml = REXML::Document.new(xml_content)
        testcase = xml.elements['testsuites/testsuite/testcase[@name="test_bar"]']
        assert_equal "ATest", testcase.attributes['classname']
        assert_equal "test_bar", testcase.attributes['name']
        assert_equal "test/dummy_test.rb", testcase.parent.attributes['filepath']
        assert_equal "ATest", testcase.parent.attributes['name']

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
        assert_equal 1, flaky_tests.count
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
      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last.strip)
      # 8 = sum of test.assertions from Minitest (skip counts as 1 in some versions)
      assert_equal 'Ran 11 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs', output

      Tempfile.open('warnings') do |warnings_file|
        out, err = capture_subprocess_io do
          system(
            @exe, 'report',
            '--queue', @redis_url,
            '--build', '1',
            '--timeout', '1',
            '--warnings-file', warnings_file.path,
            chdir: 'test/fixtures/',
          )
        end

        warnings_file.rewind
        content = warnings_file.read.lines.map { |line| JSON.parse(line) }
        assert_equal 1, content.size
        assert_equal "RESERVED_LOST_TEST", content[0]["type"]
        assert_equal "Atest#test_bar", content[0]["test"]
        assert_equal 2, content[0]["timeout"]

        assert_empty filter_deprecation_warnings(err)
        output = normalize(out)

        expected_output = <<~END
          Waiting for workers to complete
          Requeued 4 tests
          REQUEUE
          ATest#test_bar (requeued 1 times)

          REQUEUE
          ATest#test_flaky (requeued 1 times)

          REQUEUE
          ATest#test_flaky_fails_retry (requeued 1 times)

          REQUEUE
          BTest#test_bar (requeued 1 times)

          Ran 7 tests, 8 assertions, 2 failures, 1 errors, 1 skips, 4 requeues in X.XXs (aggregated)



          ================================================================================
          FAILED TESTS SUMMARY:
          ================================================================================
            test/dummy_test.rb (3 failures)
          ================================================================================

          --------------------------------------------------------------------------------
          Error 1 of 3
          --------------------------------------------------------------------------------
          FAIL ATest#test_bar
          Expected false to be truthy.
              test/dummy_test.rb:10:in `test_bar'


          --------------------------------------------------------------------------------
          Error 2 of 3
          --------------------------------------------------------------------------------
          FAIL ATest#test_flaky_fails_retry
          Expected false to be truthy.
              test/dummy_test.rb:23:in `test_flaky_fails_retry'


          --------------------------------------------------------------------------------
          Error 3 of 3
          --------------------------------------------------------------------------------
          ERROR BTest#test_bar
          Minitest::UnexpectedError: TypeError: String can't be coerced into Integer
              test/dummy_test.rb:37:in `+'
              test/dummy_test.rb:37:in `test_bar'
              test/dummy_test.rb:37:in `+'
              test/dummy_test.rb:37:in `test_bar'
          
          ================================================================================
        END
        assert_includes output, expected_output
      end
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

      assert_empty filter_deprecation_warnings(err)
      output = normalize(out.lines.last)
      assert_equal <<~END, output
        Ran 1 tests, 1 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs
      END
    end

    def test_application_error
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
          'test/bad_framework_test.rb',
          chdir: 'test/fixtures/',
        )
      end

      assert_equal 42, $?.exitstatus

      out, _ = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', '1',
          '--timeout', '1',
          '--heartbeat',
          chdir: 'test/fixtures/',
          )
      end

      assert_includes out, "Worker 1 crashed"
      assert_includes out, "Some error in the test framework"

      assert_equal 42, $?.exitstatus
    end

    private

    def normalize_xml(output)
      normalize_backtrace(freeze_xml_timing(rewrite_paths(output)))
    end
  end
end
