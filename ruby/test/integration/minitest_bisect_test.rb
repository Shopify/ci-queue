# frozen_string_literal: true
require 'test_helper'

module Integration
  class MinitestBisectTest < Minitest::Test
    include OutputTestHelpers

    def test_bisect
      out, err = capture_subprocess_io do
        run_bisect('log/leaky_test_order.log', 'LeakyTest#test_sensible_to_leak')
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS
        --- Testing the failing test in isolation
          LeakyTest#test_sensible_to_leak                                 PASS
        --- Run #1, 45 suspects left
          LeakyTest#test_useless_0                                        PASS
          LeakyTest#test_useless_1                                        PASS
          LeakyTest#test_useless_2                                        PASS
          LeakyTest#test_useless_3                                        PASS
          LeakyTest#test_useless_4                                        PASS
          LeakyTest#test_useless_5                                        PASS
          LeakyTest#test_useless_6                                        PASS
          LeakyTest#test_useless_7                                        PASS
          LeakyTest#test_useless_8                                        PASS
          LeakyTest#test_useless_9                                        PASS
          LeakyTest#test_introduce_leak                                   PASS
          LeakyTest#test_useless_10                                       PASS
          LeakyTest#test_useless_11                                       PASS
          LeakyTest#test_useless_12                                       PASS
          LeakyTest#test_useless_13                                       PASS
          LeakyTest#test_useless_14                                       PASS
          LeakyTest#test_useless_15                                       PASS
          LeakyTest#test_useless_16                                       PASS
          LeakyTest#test_useless_17                                       PASS
          LeakyTest#test_useless_18                                       PASS
          LeakyTest#test_useless_19                                       PASS
          LeakyTest#test_useless_20                                       PASS
          LeakyTest#test_useless_21                                       PASS
          LeakyTest#test_sensible_to_leak                                 FAIL

        --- Run #2, 23 suspects left
          LeakyTest#test_useless_0                                        PASS
          LeakyTest#test_useless_1                                        PASS
          LeakyTest#test_useless_2                                        PASS
          LeakyTest#test_useless_3                                        PASS
          LeakyTest#test_useless_4                                        PASS
          LeakyTest#test_useless_5                                        PASS
          LeakyTest#test_useless_6                                        PASS
          LeakyTest#test_useless_7                                        PASS
          LeakyTest#test_useless_8                                        PASS
          LeakyTest#test_useless_9                                        PASS
          LeakyTest#test_introduce_leak                                   PASS
          LeakyTest#test_useless_10                                       PASS
          LeakyTest#test_sensible_to_leak                                 FAIL

        --- Run #3, 12 suspects left
          LeakyTest#test_useless_0                                        PASS
          LeakyTest#test_useless_1                                        PASS
          LeakyTest#test_useless_2                                        PASS
          LeakyTest#test_useless_3                                        PASS
          LeakyTest#test_useless_4                                        PASS
          LeakyTest#test_useless_5                                        PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #4, 6 suspects left
          LeakyTest#test_useless_6                                        PASS
          LeakyTest#test_useless_7                                        PASS
          LeakyTest#test_useless_8                                        PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #5, 3 suspects left
          LeakyTest#test_useless_9                                        PASS
          LeakyTest#test_introduce_leak                                   PASS
          LeakyTest#test_sensible_to_leak                                 FAIL

        --- Run #6, 2 suspects left
          LeakyTest#test_useless_9                                        PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Final validation
          LeakyTest#test_introduce_leak                                   PASS
          LeakyTest#test_sensible_to_leak                                 FAIL
        +++ The following command should reproduce the leak on your machine:

        cat <<EOF |
        LeakyTest#test_introduce_leak
        LeakyTest#test_sensible_to_leak
        EOF
        bundle exec minitest-queue --queue - run -Itest test/leaky_test.rb

      EOS

      assert_equal expected_output, normalize(out)
    end

    def test_unconclusive
      out, err = capture_subprocess_io do
        run_bisect('log/unconclusive_test_order.log', 'LeakyTest#test_sensible_to_leak')
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS
        --- Testing the failing test in isolation
          LeakyTest#test_sensible_to_leak                                 PASS
        --- Run #1, 45 suspects left
          LeakyTest#test_useless_0                                        PASS
          LeakyTest#test_useless_1                                        PASS
          LeakyTest#test_useless_2                                        PASS
          LeakyTest#test_useless_3                                        PASS
          LeakyTest#test_useless_4                                        PASS
          LeakyTest#test_useless_5                                        PASS
          LeakyTest#test_useless_6                                        PASS
          LeakyTest#test_useless_7                                        PASS
          LeakyTest#test_useless_8                                        PASS
          LeakyTest#test_useless_9                                        PASS
          LeakyTest#test_harmless_test                                    PASS
          LeakyTest#test_useless_10                                       PASS
          LeakyTest#test_useless_11                                       PASS
          LeakyTest#test_useless_12                                       PASS
          LeakyTest#test_useless_13                                       PASS
          LeakyTest#test_useless_14                                       PASS
          LeakyTest#test_useless_15                                       PASS
          LeakyTest#test_useless_16                                       PASS
          LeakyTest#test_useless_17                                       PASS
          LeakyTest#test_useless_18                                       PASS
          LeakyTest#test_useless_19                                       PASS
          LeakyTest#test_useless_20                                       PASS
          LeakyTest#test_useless_21                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #2, 22 suspects left
          LeakyTest#test_useless_22                                       PASS
          LeakyTest#test_useless_23                                       PASS
          LeakyTest#test_useless_24                                       PASS
          LeakyTest#test_useless_25                                       PASS
          LeakyTest#test_useless_26                                       PASS
          LeakyTest#test_useless_27                                       PASS
          LeakyTest#test_useless_28                                       PASS
          LeakyTest#test_useless_29                                       PASS
          LeakyTest#test_useless_30                                       PASS
          LeakyTest#test_useless_31                                       PASS
          LeakyTest#test_useless_32                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #3, 11 suspects left
          LeakyTest#test_useless_33                                       PASS
          LeakyTest#test_useless_34                                       PASS
          LeakyTest#test_useless_35                                       PASS
          LeakyTest#test_useless_36                                       PASS
          LeakyTest#test_useless_37                                       PASS
          LeakyTest#test_useless_38                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #4, 5 suspects left
          LeakyTest#test_useless_39                                       PASS
          LeakyTest#test_useless_40                                       PASS
          LeakyTest#test_useless_41                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Run #5, 2 suspects left
          LeakyTest#test_useless_42                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS

        --- Final validation
          LeakyTest#test_useless_43                                       PASS
          LeakyTest#test_sensible_to_leak                                 PASS
        --- The bisection was inconclusive, there might not be any leaky test here.
      EOS

      assert_equal expected_output, normalize(out)
    end

    def test_broken
      out, err = capture_subprocess_io do
        run_bisect('log/broken_test_order.log', 'LeakyTest#test_broken_test')
      end

      assert_empty err
      expected_output = strip_heredoc <<-EOS
        --- Testing the failing test in isolation
          LeakyTest#test_broken_test                                      FAIL
        ^^^ +++

        The test fail when ran alone, no need to bisect.
      EOS

      assert_equal expected_output, normalize(out)
    end

    private

    def normalize(output)
      rewrite_paths(freeze_seed(freeze_timing(decolorize_output(output))))
    end

    def run_bisect(test_order_file, failing_test)
      exe = File.expand_path('../../../exe/minitest-queue', __FILE__)
      system(
        { 'BUILDKITE' => '1' },
        exe, 'bisect',
        '--queue', test_order_file,
        '--failing-test', failing_test,
        '-Itest',
        'test/leaky_test.rb',
        chdir: 'test/fixtures/',
      )
    end
  end
end
