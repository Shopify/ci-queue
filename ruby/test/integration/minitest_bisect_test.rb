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
        Started with run options --seed XXXXX

        LeakyTest
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        1 tests, 1 assertions, 0 failures, 0 errors, 0 skips
        --- Run #1, 45 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_0                                                  PASS (X.XXs)
          test_useless_1                                                  PASS (X.XXs)
          test_useless_2                                                  PASS (X.XXs)
          test_useless_3                                                  PASS (X.XXs)
          test_useless_4                                                  PASS (X.XXs)
          test_useless_5                                                  PASS (X.XXs)
          test_useless_6                                                  PASS (X.XXs)
          test_useless_7                                                  PASS (X.XXs)
          test_useless_8                                                  PASS (X.XXs)
          test_useless_9                                                  PASS (X.XXs)
          test_introduce_leak                                             PASS (X.XXs)
          test_useless_10                                                 PASS (X.XXs)
          test_useless_11                                                 PASS (X.XXs)
          test_useless_12                                                 PASS (X.XXs)
          test_useless_13                                                 PASS (X.XXs)
          test_useless_14                                                 PASS (X.XXs)
          test_useless_15                                                 PASS (X.XXs)
          test_useless_16                                                 PASS (X.XXs)
          test_useless_17                                                 PASS (X.XXs)
          test_useless_18                                                 PASS (X.XXs)
          test_useless_19                                                 PASS (X.XXs)
          test_useless_20                                                 PASS (X.XXs)
          test_useless_21                                                 PASS (X.XXs)
          test_sensible_to_leak                                           FAIL (X.XXs)
        Minitest::Assertion:         Expected: false
                  Actual: true
                ./test/fixtures/test/leaky_test.rb:24:in `test_sensible_to_leak'


        Finished in X.XXs
        24 tests, 24 assertions, 1 failures, 0 errors, 0 skips

        --- Run #2, 23 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_0                                                  PASS (X.XXs)
          test_useless_1                                                  PASS (X.XXs)
          test_useless_2                                                  PASS (X.XXs)
          test_useless_3                                                  PASS (X.XXs)
          test_useless_4                                                  PASS (X.XXs)
          test_useless_5                                                  PASS (X.XXs)
          test_useless_6                                                  PASS (X.XXs)
          test_useless_7                                                  PASS (X.XXs)
          test_useless_8                                                  PASS (X.XXs)
          test_useless_9                                                  PASS (X.XXs)
          test_introduce_leak                                             PASS (X.XXs)
          test_useless_10                                                 PASS (X.XXs)
          test_sensible_to_leak                                           FAIL (X.XXs)
        Minitest::Assertion:         Expected: false
                  Actual: true
                ./test/fixtures/test/leaky_test.rb:24:in `test_sensible_to_leak'


        Finished in X.XXs
        13 tests, 13 assertions, 1 failures, 0 errors, 0 skips

        --- Run #3, 12 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_0                                                  PASS (X.XXs)
          test_useless_1                                                  PASS (X.XXs)
          test_useless_2                                                  PASS (X.XXs)
          test_useless_3                                                  PASS (X.XXs)
          test_useless_4                                                  PASS (X.XXs)
          test_useless_5                                                  PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        7 tests, 7 assertions, 0 failures, 0 errors, 0 skips

        --- Run #4, 6 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_6                                                  PASS (X.XXs)
          test_useless_7                                                  PASS (X.XXs)
          test_useless_8                                                  PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        4 tests, 4 assertions, 0 failures, 0 errors, 0 skips

        --- Run #5, 3 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_9                                                  PASS (X.XXs)
          test_introduce_leak                                             PASS (X.XXs)
          test_sensible_to_leak                                           FAIL (X.XXs)
        Minitest::Assertion:         Expected: false
                  Actual: true
                ./test/fixtures/test/leaky_test.rb:24:in `test_sensible_to_leak'


        Finished in X.XXs
        3 tests, 3 assertions, 1 failures, 0 errors, 0 skips

        --- Run #6, 2 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_9                                                  PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        2 tests, 2 assertions, 0 failures, 0 errors, 0 skips

        --- Final validation
        Started with run options --seed XXXXX

        LeakyTest
          test_introduce_leak                                             PASS (X.XXs)
          test_sensible_to_leak                                           FAIL (X.XXs)
        Minitest::Assertion:         Expected: false
                  Actual: true
                ./test/fixtures/test/leaky_test.rb:24:in `test_sensible_to_leak'


        Finished in X.XXs
        2 tests, 2 assertions, 1 failures, 0 errors, 0 skips
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
        Started with run options --seed XXXXX

        LeakyTest
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        1 tests, 1 assertions, 0 failures, 0 errors, 0 skips
        --- Run #1, 45 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_0                                                  PASS (X.XXs)
          test_useless_1                                                  PASS (X.XXs)
          test_useless_2                                                  PASS (X.XXs)
          test_useless_3                                                  PASS (X.XXs)
          test_useless_4                                                  PASS (X.XXs)
          test_useless_5                                                  PASS (X.XXs)
          test_useless_6                                                  PASS (X.XXs)
          test_useless_7                                                  PASS (X.XXs)
          test_useless_8                                                  PASS (X.XXs)
          test_useless_9                                                  PASS (X.XXs)
          test_harmless_test                                              PASS (X.XXs)
          test_useless_10                                                 PASS (X.XXs)
          test_useless_11                                                 PASS (X.XXs)
          test_useless_12                                                 PASS (X.XXs)
          test_useless_13                                                 PASS (X.XXs)
          test_useless_14                                                 PASS (X.XXs)
          test_useless_15                                                 PASS (X.XXs)
          test_useless_16                                                 PASS (X.XXs)
          test_useless_17                                                 PASS (X.XXs)
          test_useless_18                                                 PASS (X.XXs)
          test_useless_19                                                 PASS (X.XXs)
          test_useless_20                                                 PASS (X.XXs)
          test_useless_21                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        24 tests, 24 assertions, 0 failures, 0 errors, 0 skips

        --- Run #2, 22 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_22                                                 PASS (X.XXs)
          test_useless_23                                                 PASS (X.XXs)
          test_useless_24                                                 PASS (X.XXs)
          test_useless_25                                                 PASS (X.XXs)
          test_useless_26                                                 PASS (X.XXs)
          test_useless_27                                                 PASS (X.XXs)
          test_useless_28                                                 PASS (X.XXs)
          test_useless_29                                                 PASS (X.XXs)
          test_useless_30                                                 PASS (X.XXs)
          test_useless_31                                                 PASS (X.XXs)
          test_useless_32                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        12 tests, 12 assertions, 0 failures, 0 errors, 0 skips

        --- Run #3, 11 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_33                                                 PASS (X.XXs)
          test_useless_34                                                 PASS (X.XXs)
          test_useless_35                                                 PASS (X.XXs)
          test_useless_36                                                 PASS (X.XXs)
          test_useless_37                                                 PASS (X.XXs)
          test_useless_38                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        7 tests, 7 assertions, 0 failures, 0 errors, 0 skips

        --- Run #4, 5 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_39                                                 PASS (X.XXs)
          test_useless_40                                                 PASS (X.XXs)
          test_useless_41                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        4 tests, 4 assertions, 0 failures, 0 errors, 0 skips

        --- Run #5, 2 suspects left
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_42                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        2 tests, 2 assertions, 0 failures, 0 errors, 0 skips

        --- Final validation
        Started with run options --seed XXXXX

        LeakyTest
          test_useless_43                                                 PASS (X.XXs)
          test_sensible_to_leak                                           PASS (X.XXs)

        Finished in X.XXs
        2 tests, 2 assertions, 0 failures, 0 errors, 0 skips
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
        Started with run options --seed XXXXX

        LeakyTest
          test_broken_test                                                FAIL (X.XXs)
        Minitest::Assertion:         Expected false to be truthy.
                ./test/fixtures/test/leaky_test.rb:32:in `test_broken_test'


        Finished in X.XXs
        1 tests, 1 assertions, 1 failures, 0 errors, 0 skips
        ^^^ +++

        The test fail when run alone, no need to bisect.
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
