# frozen_string_literal: true
module Minitest
  module Queue
    class BuildStatusReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers

      def initialize(supervisor:, **options)
        @supervisor = supervisor
        @build = supervisor.build
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

      def requeued_tests
        build.requeued_tests
      end

      def report
        if requeued_tests.to_a.any?
          step("Requeued #{requeued_tests.size} tests")
          requeued_tests.to_a.sort.each do |test_id, count|
            puts yellow("REQUEUE")
            puts "#{test_id} (requeued #{count} times)"
            puts ""
          end
        end

        puts aggregates

        if supervisor.time_left.to_i <= 0
          puts red("Timed out waiting for tests to be executed.")

          remaining_tests = supervisor.test_ids
          remaining_tests.first(10).each do |id|
            puts "  #{id}"
          end

          if remaining_tests.size > 10
            puts "  ..."
          end
        elsif supervisor.time_left_with_no_workers.to_i <= 0
          puts red("All workers died.")
        elsif supervisor.max_test_failed?
          puts red("Encountered too many failed tests. Test run was ended early.")
        end

        puts

        errors = error_reports
        puts errors

        build.worker_errors.to_a.sort.each do |worker_id, error|
          puts red("Worker #{worker_id } crashed")
          puts error
          puts ""
        end

        success?
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

      def write_failure_file(file)
        File.write(file, error_reports.map(&:to_h).to_json)
      end

      def write_flaky_tests_file(file)
        File.write(file, flaky_reports.to_json)
      end

      private

      attr_reader :build, :supervisor

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
