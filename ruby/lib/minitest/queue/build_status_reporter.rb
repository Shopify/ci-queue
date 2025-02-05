# frozen_string_literal: true
module Minitest
  module Queue
    class BuildStatusReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers

      def initialize(build:, **options)
        @build = build
        super(options)
      end

      def completed?
        build.queue_exhausted?
      end

      def error_reports
        build.error_reports.sort_by(&:first).map { |k, v| ErrorReport.load(v) }
      end

      def flaky_reports
        build.flaky_reports
      end

      def executed_tests
        build.executed_tests
      end

      def requeued_tests
        build.requeued_tests
      end

      def report
        puts aggregates
        errors = error_reports
        puts errors

        requeued_tests.to_a.sort.each do |test_id, count|
          puts yellow("REQUEUE")
          puts "#{test_id} (requeued #{count} times)"
          puts ""
        end

        build.worker_errors.to_a.sort.each do |worker_id, error|
          puts red("Worker #{worker_id } crashed")
          puts error
          puts ""
        end

        errors.empty?
      end

      def success?
        build.error_reports.empty? &&
          build.worker_errors.empty?
      end

      def record(*)
        raise NotImplementedError
      end

      def failures
        fetch_summary['failures'].to_i
      end

      def errors
        fetch_summary['errors'].to_i
      end

      def assertions
        fetch_summary['assertions'].to_i
      end

      def skips
        fetch_summary['skips'].to_i
      end

      def requeues
        fetch_summary['requeues'].to_i
      end

      def total_time
        fetch_summary['total_time'].to_f
      end

      def progress
        build.progress
      end

      def write_summary_file(total_tests, file)
        File.write(file, {
          total_tests: total_tests,
          failures: failures,
          errors: errors,
          skips: skips,
          requeues: requeues,
          total_executed_tests: executed_tests.size,
          executed_tests: executed_tests,
        }.to_json)
      end

      def write_failure_file(file)
        File.write(file, error_reports.map(&:to_h).to_json)
      end

      def write_flaky_tests_file(file)
        File.write(file, flaky_reports.to_json)
      end

      private

      attr_reader :build

      def aggregates
        success = failures.zero? && errors.zero?
        failures_count = "#{failures} failures, #{errors} errors,"

        step([
          'Ran %d tests, %d assertions,' % [progress, assertions],
          success ? green(failures_count) : red(failures_count),
          yellow("#{skips} skips, #{requeues} requeues"),
          'in %.2fs (aggregated)' % total_time,
        ].join(' '), collapsed: success)
      end

      def fetch_summary
        @summary ||= build.fetch_stats(BuildStatusRecorder::COUNTERS)
      end
    end
  end
end
