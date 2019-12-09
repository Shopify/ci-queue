# frozen_string_literal: true
require 'minitest/reporters'

module Minitest
  module Queue
    class GrindReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers

      def initialize(build:, **options)
        @build = build
        @success = true
        super(options)
      end

      def report
        puts '+++ Results'

        if flaky_tests.empty?
          puts green('all tests passed every time, grinding did not uncover any flakiness')
          return
        end
        @success = false

        flaky_tests.each do |name, errors|
          total_runs = fetch_counts(name)
          flakiness_percentage = (errors.count / total_runs) * 100

          error_messages = errors.map do |message|
            message.to_s.lines.map { |l| "\t#{l}"}.join
          end.to_set.to_a.join("\n\n")

          puts <<~EOS
            #{red(name)}
            Runs: #{total_runs.to_i}
            Failures: #{errors.count}
            Flakiness Percentage: #{flakiness_percentage.to_i}%
            Errors:
            #{error_messages}
          EOS
        end
      end

      def success?
        @success
      end

      def flaky_tests
        @flaky_tests ||= begin
          flaky_tests = {}
          build.error_reports.each do |error|
            err = ErrorReport.load(error)
            name = err.test_and_module_name
            flaky_tests[name] ||= []
            flaky_tests[name] << err
          end
          flaky_tests
        end
      end

      def record(*)
        raise NotImplementedError
      end

      def fetch_counts(test)
        key = "count##{test}"
        build.fetch_stats([key])[key]
      end

      private

      attr_reader :build
    end
  end
end
