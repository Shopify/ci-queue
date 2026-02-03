# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

module Integration
  class MinitestLazyLoadTest < Minitest::Test
    include OutputTestHelpers

    def setup
      @redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
      @redis = Redis.new(url: @redis_url)
      @redis.flushdb
      @exe = File.expand_path('../../../exe/minitest-queue', __FILE__)
      @fixtures_path = File.expand_path('../../fixtures', __FILE__)
    end

    def test_lazy_load_single_worker
      # dummy_test.rb has ATest (5 tests) + BTest (2 tests) = 7 tests total
      out, _err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-single-1',
          '--worker', '1',
          '--timeout', '5',
          '--lazy-load',
          '--test-helpers', 'test/test_helper.rb',
          '-Itest',
          'test/dummy_test.rb',
          chdir: @fixtures_path,
        )
      end

      assert_match(/Leader loaded/, out)
      assert_match(/Leader loaded 1 test files/, out)
      assert_match(/7 tests/, out)
    end

    def test_lazy_load_multiple_workers
      @redis.flushdb

      # First worker becomes leader
      out1, _err1 = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-multi-1',
          '--worker', '1',
          '--timeout', '5',
          '--lazy-load',
          '--test-helpers', 'test/test_helper.rb',
          '-Itest',
          'test/dummy_test.rb',
          chdir: @fixtures_path,
        )
      end

      # Leader should have loaded the test files
      assert_match(/Leader loaded \d+ test files/, out1)

      # Second worker becomes consumer (queue already exhausted, but we verify
      # manifest was stored and consumer mode is working)
      out2, _err2 = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-multi-1',
          '--worker', '2',
          '--timeout', '5',
          '--lazy-load',
          '--test-helpers', 'test/test_helper.rb',
          '-Itest',
          'test/dummy_test.rb',
          chdir: @fixtures_path,
        )
      end

      # Second worker should NOT be leader (no "Leader loaded" message)
      refute_match(/Leader loaded/, out2)
      # Second worker should report queue exhausted or no tests to run
      assert out2.include?('All tests were ran already') || out2.include?('Ran 0 tests'),
             "Second worker should find queue exhausted. Output: #{out2}"

      # Check the report to verify all tests ran
      report_out, _report_err = capture_subprocess_io do
        system(
          @exe, 'report',
          '--queue', @redis_url,
          '--build', 'lazy-multi-1',
          '--timeout', '5',
          chdir: @fixtures_path,
        )
      end

      assert_match(/7 tests/, report_out)
    end

    def test_lazy_load_with_failing_test
      # Create a temporary failing test
      Dir.mktmpdir do |tmpdir|
        # Copy test helper and create log directory
        FileUtils.cp(File.join(@fixtures_path, 'test', 'test_helper.rb'), tmpdir)
        FileUtils.cp(File.join(@fixtures_path, 'test', 'backtrace_filters.rb'), tmpdir)
        FileUtils.mkdir_p(File.join(tmpdir, 'log'))

        # Create a failing test
        File.write(File.join(tmpdir, 'failing_lazy_test.rb'), <<~RUBY)
          require_relative 'test_helper'

          class FailingLazyTest < Minitest::Test
            def test_will_fail
              assert false, "This test intentionally fails"
            end

            def test_will_pass
              assert true
            end
          end
        RUBY

        out, _err = capture_subprocess_io do
          system(
            @exe, 'run',
            '--queue', @redis_url,
            '--seed', 'foobar',
            '--build', 'lazy-fail-1',
            '--worker', '1',
            '--timeout', '5',
            '--lazy-load',
            '--test-helpers', 'test_helper.rb',
            '-I.',
            'failing_lazy_test.rb',
            chdir: tmpdir,
          )
        end

        refute_predicate $?, :success?, "Command should have failed"
        assert_match(/Leader loaded/, out)
        result = normalize(find_summary_line(out))
        assert_equal 'Ran 2 tests, 2 assertions, 1 failures, 0 errors, 0 skips, 0 requeues in X.XXs', result
        assert_match(/Worker stats: leader, \d+ files loaded, \d+ MB peak memory, lazy loading enabled/, out)
      end
    end

    def test_lazy_load_without_test_helpers
      # Test that lazy load works even without specifying test helpers
      # Use passing_test.rb which requires test_helper internally
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-no-helpers-1',
          '--worker', '1',
          '--timeout', '5',
          '--lazy-load',
          '-Itest',
          'test/passing_test.rb',
          chdir: @fixtures_path,
        )
      end

      assert_predicate $?, :success?, "Command failed with stderr: #{err}\nstdout: #{out}"
      assert_match(/Leader loaded/, out)
    end

    def test_lazy_load_via_environment_variable
      out, err = capture_subprocess_io do
        system(
          {
            'CI_QUEUE_LAZY_LOAD' => 'true',
            'CI_QUEUE_TEST_HELPERS' => 'test/test_helper.rb',
          },
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-env-1',
          '--worker', '1',
          '--timeout', '5',
          '-Itest',
          'test/passing_test.rb',
          chdir: @fixtures_path,
        )
      end

      assert_predicate $?, :success?, "Command failed with stderr: #{err}\nstdout: #{out}"
      assert_match(/Leader loaded/, out)
    end

    def test_lazy_load_with_requeue
      Dir.mktmpdir do |tmpdir|
        # Copy test helper and create log directory
        FileUtils.cp(File.join(@fixtures_path, 'test', 'test_helper.rb'), tmpdir)
        FileUtils.cp(File.join(@fixtures_path, 'test', 'backtrace_filters.rb'), tmpdir)
        FileUtils.mkdir_p(File.join(tmpdir, 'log'))

        # Create a flaky test that fails on first attempt
        File.write(File.join(tmpdir, 'flaky_lazy_test.rb'), <<~RUBY)
          require_relative 'test_helper'

          class FlakyLazyTest < Minitest::Test
            def test_flaky
              @attempt_file = File.join(Dir.tmpdir, 'flaky_lazy_test_attempt')
              if File.exist?(@attempt_file)
                assert true
              else
                File.write(@attempt_file, '1')
                assert false, "First attempt fails"
              end
            end
          end
        RUBY

        # Clean up attempt file
        attempt_file = File.join(Dir.tmpdir, 'flaky_lazy_test_attempt')
        File.delete(attempt_file) if File.exist?(attempt_file)

        out, err = capture_subprocess_io do
          system(
            @exe, 'run',
            '--queue', @redis_url,
            '--seed', 'foobar',
            '--build', 'lazy-requeue-1',
            '--worker', '1',
            '--timeout', '5',
            '--max-requeues', '1',
            '--requeue-tolerance', '1',
            '--lazy-load',
            '--test-helpers', 'test_helper.rb',
            '-I.',
            'flaky_lazy_test.rb',
            chdir: tmpdir,
          )
        end

        assert_predicate $?, :success?, "Command failed with stderr: #{err}\nstdout: #{out}"
        assert_match(/Leader loaded/, out)
        result = normalize(find_summary_line(out))
        assert_equal 'Ran 2 tests, 2 assertions, 0 failures, 0 errors, 0 skips, 1 requeues in X.XXs', result
        assert_match(/Worker stats: leader, \d+ files loaded, \d+ MB peak memory, lazy loading enabled/, out)
      ensure
        File.delete(attempt_file) if File.exist?(attempt_file)
      end
    end

    def test_lazy_load_manifest_stored_in_redis
      @redis.flushdb

      _out, _err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-manifest-1',
          '--worker', '1',
          '--timeout', '5',
          '--lazy-load',
          '--test-helpers', 'test/test_helper.rb',
          '-Itest',
          'test/dummy_test.rb',
          chdir: @fixtures_path,
        )
      end

      # Verify manifest was stored in Redis
      manifest_key = CI::Queue::Redis::KeyShortener.key('lazy-manifest-1', 'manifest')
      manifest = @redis.hgetall(manifest_key)

      refute_empty manifest, "Manifest should be stored in Redis"
      assert manifest.key?('ATest'), "Manifest should contain ATest"
      assert manifest.key?('BTest'), "Manifest should contain BTest"
      assert_match(/dummy_test\.rb/, manifest['ATest'])
      assert_match(/dummy_test\.rb/, manifest['BTest'])
    end

    def test_lazy_load_invalid_test_file_path
      out, err = capture_subprocess_io do
        system(
          @exe, 'run',
          '--queue', @redis_url,
          '--seed', 'foobar',
          '--build', 'lazy-invalid-1',
          '--worker', '1',
          '--timeout', '5',
          '--lazy-load',
          '-Itest',
          'test/nonexistent_test.rb',
          chdir: @fixtures_path,
        )
      end

      refute_predicate $?, :success?, "Command should have failed for invalid path"
      combined_output = out + err
      assert_match(/do not exist|cannot load|no such file/i, combined_output)
    end

    # This test verifies that lazy loading provides significant memory savings
    # by comparing memory usage between eager and lazy loading modes.
    #
    # With eager loading: ALL test files are loaded by every worker at startup
    # With lazy loading: Only the leader loads all files; consumers load on-demand
    #
    # We generate 100 test files with 50 tests each (5,000 tests total).
    # Each file defines a class with constants to ensure measurable memory usage.
    #
    # Test strategy:
    # - Eager mode: Single worker loads all 100 files, runs all 5,000 tests
    # - Lazy mode: Leader loads all files, consumers load nothing (queue exhausted)
    #   Consumers should use significantly less memory than eager workers
    def test_lazy_load_memory_savings
      Dir.mktmpdir do |tmpdir|
        setup_test_environment_for_memory_test(tmpdir)

        # Measure eager loading memory (single worker loads all files)
        @redis.flushdb
        eager_memory = measure_worker_memory_external(
          tmpdir: tmpdir,
          build_id: 'memory-eager-1',
          worker_id: '1',
          lazy_load: false,
        )

        # For lazy loading, run leader then consumers
        # Leader loads all files, consumers find queue exhausted and load nothing
        @redis.flushdb
        lazy_memories = []

        # Start 3 workers sequentially: leader + 2 consumers
        3.times do |i|
          memory = measure_worker_memory_external(
            tmpdir: tmpdir,
            build_id: 'memory-lazy-1',
            worker_id: i.to_s,
            lazy_load: true,
          )
          lazy_memories << memory
        end

        leader_memory = lazy_memories.first
        consumer_memories = lazy_memories[1..-1].reject(&:zero?)

        if consumer_memories.any?
          avg_consumer_memory = consumer_memories.sum / consumer_memories.size

          # Consumers should use significantly less memory than eager mode
          savings_percentage = ((eager_memory - avg_consumer_memory).to_f / eager_memory * 100).round(1)

          # Output memory stats for debugging/verification
          if ENV['CI_QUEUE_DEBUG']
            puts "\nMemory savings: Eager=#{format_memory(eager_memory)}, " \
                 "Consumer=#{format_memory(avg_consumer_memory)}, Savings=#{savings_percentage}%"
          end

          assert avg_consumer_memory < eager_memory,
                 "Lazy consumer (#{format_memory(avg_consumer_memory)}) should use less memory than " \
                 "eager worker (#{format_memory(eager_memory)})"

          assert savings_percentage > 20,
                 "Expected >20% memory savings, got #{savings_percentage}%. " \
                 "Eager: #{format_memory(eager_memory)}, " \
                 "Avg consumer: #{format_memory(avg_consumer_memory)}"
        else
          # If no consumers got to run, just verify lazy mode doesn't add overhead
          diff_percentage = ((leader_memory - eager_memory).to_f / eager_memory * 100).abs.round(1)
          assert diff_percentage < 50,
                 "Lazy leader memory should be within 50% of eager. " \
                 "Eager: #{format_memory(eager_memory)}, Leader: #{format_memory(leader_memory)}"
        end
      end
    end

    private

    def setup_test_environment_for_memory_test(tmpdir)
      # Create log directory for order reporter
      FileUtils.mkdir_p(File.join(tmpdir, 'log'))

      # Create minimal test helper
      File.write(File.join(tmpdir, 'test_helper.rb'), <<~RUBY)
        require 'minitest/autorun'
      RUBY

      # Generate 100 test files with 50 tests each = 5,000 tests
      # Each class has constants to ensure memory usage scales with loaded files
      num_files = 100
      tests_per_file = 50

      num_files.times do |file_idx|
        class_name = "GeneratedTest#{file_idx.to_s.rjust(3, '0')}"

        test_methods = tests_per_file.times.map do |test_idx|
          "  def test_method_#{test_idx}\n    assert true\n  end"
        end.join("\n\n")

        # Each class has constants with data to ensure memory usage
        # This simulates real test files that have fixtures, constants, etc.
        constants = 5.times.map do |i|
          "  CONSTANT_#{i} = #{Array.new(50) { rand(1000) }.inspect}"
        end.join("\n")

        File.write(File.join(tmpdir, "test_#{file_idx.to_s.rjust(3, '0')}.rb"), <<~RUBY)
          require_relative 'test_helper'

          class #{class_name} < Minitest::Test
          #{constants}

          #{test_methods}
          end
        RUBY
      end

      # Generate list of test files
      @generated_test_files = num_files.times.map do |i|
        "test_#{i.to_s.rjust(3, '0')}.rb"
      end
    end

    def measure_worker_memory_external(tmpdir:, build_id:, worker_id:, lazy_load:)
      args = [
        @exe, 'run',
        '--queue', @redis_url,
        '--seed', 'foobar',
        '--build', build_id,
        '--worker', worker_id,
        '--timeout', '300',
        '--test-helpers', 'test_helper.rb',
        '-I.',
      ]

      args += ['--lazy-load'] if lazy_load
      args += @generated_test_files

      # Use a wrapper script to measure peak memory
      memory_file = File.join(tmpdir, "memory_#{worker_id}.txt")

      # Create wrapper script that monitors memory
      wrapper = File.join(tmpdir, "wrapper_#{worker_id}.sh")
      File.write(wrapper, <<~BASH)
        #!/bin/bash
        # Start the process and get its PID
        "$@" &
        PID=$!

        # Track peak memory
        PEAK_RSS=0
        while kill -0 $PID 2>/dev/null; do
          if [[ "$OSTYPE" == "darwin"* ]]; then
            RSS=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ')
          else
            RSS=$(cat /proc/$PID/statm 2>/dev/null | awk '{print $2 * 4}')
          fi
          if [[ -n "$RSS" && "$RSS" -gt "$PEAK_RSS" ]]; then
            PEAK_RSS=$RSS
          fi
          sleep 0.1
        done
        wait $PID
        echo $PEAK_RSS > #{memory_file}
      BASH
      FileUtils.chmod(0755, wrapper)

      capture_subprocess_io do
        system(wrapper, *args, chdir: tmpdir)
      end

      if File.exist?(memory_file)
        File.read(memory_file).strip.to_i
      else
        0
      end
    end

    def format_memory(kb)
      if kb > 1024 * 1024
        "#{(kb / 1024.0 / 1024.0).round(1)} GB"
      elsif kb > 1024
        "#{(kb / 1024.0).round(1)} MB"
      else
        "#{kb} KB"
      end
    end
  end
end
