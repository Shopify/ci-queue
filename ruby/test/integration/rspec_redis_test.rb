require 'test_helper'

module Integration
  class RSpecRedisTest < Minitest::Test
    include OutputTestHelpers

    def setup
      @redis_url = "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7"
      @redis = Redis.new(url: @redis_url)
      @redis.flushdb
      @exe = File.expand_path('../../../exe/rspec-queue', __FILE__)
    end

    def test_redis_runner
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          chdir: 'test/fixtures/',
        )
        assert_equal 0, $?.exitstatus
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123
        ..*.

        Pending: (Failures listed here are expected and do not affect your suite's status)

          1) Object doesn't work on first try
             # The example failed, but another attempt will be done to rule out flakiness

             Failure/Error: expect(1 + 1).to be == 42

               expected: == 42
                    got:    2
             # ./spec/dummy_spec.rb:11:in `block (2 levels) in <top (required)>'
             # ./spec/dummy_spec.rb:6

        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        4 examples, 0 failures, 1 pending

        Randomized with seed 123

      EOS

      assert_equal expected_output, normalize(out)
    end

    def test_redis_runner_retry
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123
        ..*.

        Pending: (Failures listed here are expected and do not affect your suite's status)

          1) Object doesn't work on first try
             # The example failed, but another attempt will be done to rule out flakiness

             Failure/Error: expect(1 + 1).to be == 42

               expected: == 42
                    got:    2
             # ./spec/dummy_spec.rb:11:in `block (2 levels) in <top (required)>'
             # ./spec/dummy_spec.rb:6

        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        4 examples, 0 failures, 1 pending

        Randomized with seed 123

      EOS
      assert_equal expected_output, normalize(out)
      assert_equal 0, $?.exitstatus

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--retry',
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123


        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        0 examples, 0 failures

        Randomized with seed 123

      EOS

      assert_equal expected_output, normalize(out)
      assert_equal 0, $?.exitstatus
    end


    def test_before_suite_errors
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '1',
          '--requeue-tolerance', '1',
          chdir: 'test/fixtures/before_suite',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123

        An error occurred in a `before(:suite)` hook.
        Failure/Error: raise "Whoops"

        RuntimeError:
          Whoops
        # ./spec/spec_helper.rb:4:in `block (2 levels) in <top (required)>'


        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        0 examples, 0 failures, 1 error occurred outside of examples

        Randomized with seed 123

      EOS

      assert_equal expected_output, normalize(out)
      assert_equal 0, $?.exitstatus
    end

    def test_report
      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          '--max-requeues', '0',
          '--requeue-tolerance', '0',
          chdir: 'test/fixtures/',
        )
        assert_equal 1, $?.exitstatus
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123
        ..F

        Failures:

          1) Object doesn't work on first try
             Failure/Error: expect(1 + 1).to be == 42

               expected: == 42
                    got:    2
             # ./spec/dummy_spec.rb:11:in `block (2 levels) in <top (required)>'

        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        3 examples, 1 failure

        Failed examples:

        rspec ./spec/dummy_spec.rb:6 # Object doesn't work on first try

        Randomized with seed 123

      EOS

      assert_equal expected_output, normalize(out)

      out, err = capture_subprocess_io do
        system(
          { 'BUILDKITE' => '1', 'SHOPIFY_BUILD_COMMIT' => 'aaaaaaaaaaaaa' },
          @exe,
          '--queue', @redis_url,
          '--build', '1',
          '--report',
          '--timeout', '5',
          chdir: 'test/fixtures/',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS
        --- Waiting for workers to complete
        +++ 1 error found

          Object doesn't work on first try
          Failure/Error: expect(1 + 1).to be == 42

            expected: == 42
                 got:    2
          # ./spec/dummy_spec.rb:11:in `block (2 levels) in <top (required)>'

        rspec ./spec/dummy_spec.rb:6 # Object doesn't work on first try
      EOS

      assert_equal expected_output, normalize(out)
    end

    def test_world_wants_to_quit
      out, err = capture_subprocess_io do
        system(
          { 'EARLY_EXIT' => '1' },
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '1',
          '--timeout', '1',
          chdir: 'test/fixtures/early_exit_suite',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123


        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        0 examples, 0 failures

        Randomized with seed 123

      EOS
      assert_equal expected_output, normalize(out)

      assert_equal 0, $?.exitstatus


      out, err = capture_subprocess_io do
        system(
          @exe,
          '--queue', @redis_url,
          '--seed', '123',
          '--build', '1',
          '--worker', '2',
          '--timeout', '1',
          chdir: 'test/fixtures/early_exit_suite',
        )
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS

        Randomized with seed 123
        F

        Failures:

          1) Object should be executed
             Failure/Error: expect(1 + 1).to be == 4

               expected: == 4
                    got:    2
             # ./spec/dummy_spec.rb:5:in `block (2 levels) in <top (required)>'

        Finished in X.XXXXX seconds (files took X.XXXXX seconds to load)
        1 example, 1 failure

        Failed examples:

        rspec ./spec/dummy_spec.rb:4 # Object should be executed

        Randomized with seed 123

      EOS

      assert_equal expected_output, normalize(out)
      assert_equal 1, $?.exitstatus
    end

    private

    def normalize(output)
      strip_blank_lines(rewrite_paths(freeze_timing(decolorize_output(output))))
    end
  end
end
