# frozen_string_literal: true
require 'test_helper'

module Minitest
  module Queue
    class TimeReporterTest < Minitest::Test
      include OutputTestHelpers

      def test_report_no_offending_tests
        build = mock_build({'some test': [0.01, 0.02, 0.2]})
        reporter = TestTimeReporter.new(build: build, limit: 0.1, percentile: 0.5)

        output, err = capture_subprocess_io do
          reporter.report
        end

        expected_output = <<~EOS
          +++ Test Time Report
          \e[32mThe 50th of test execution time is within 0.1 milliseconds.\e[0m
        EOS
        assert_equal expected_output, output
        assert_empty err
        assert reporter.success?
      end

      def test_report_not_turned_on
        build = mock_build({'some test': [0.01, 0.02, 0.2]})
        reporter = TestTimeReporter.new(build: build)

        output, err = capture_subprocess_io do
          reporter.report
        end

        assert_equal "", output
        assert_empty err
        assert reporter.success?
      end

      def test_report_found_offending_tests
        build = mock_build({'some test': [0.01, 0.03, 0.2]})
        reporter = TestTimeReporter.new(build: build, limit: 0.02, percentile: 0.5)

        output, err = capture_subprocess_io do
          reporter.report
        end

        expected_output = <<~EOS
          +++ Test Time Report
          Detected 1 test(s) over the desired time limit.
          Please make them faster than 0.02ms in the 50th percentile.
          some test: 0.03ms
        EOS
        assert_equal expected_output, normalize(output)
        assert_empty err
        refute reporter.success?
      end

      private

      def mock_build(test_time_hash)
        build = MiniTest::Mock.new
        build.expect(:fetch, test_time_hash)
        build
      end
    end
  end
end
