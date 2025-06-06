# frozen_string_literal: true
module Minitest
  module Queue
    class BuildStatusReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers

      class JUnitReporter
        def initialize(file, error_reports)
          @file = file
          @error_reports = error_reports
        end

        def write
          File.open(@file, 'w+') do |file|
            format_document(generate_document(@error_reports), file)
          end
        end

        private

        def generate_document(error_reports)
          suites = error_reports.group_by { |error_report| error_report.test_suite }

          doc = REXML::Document.new(nil, {
            :prologue_quote => :quote,
            :attribute_quote => :quote,
          })
          doc << REXML::XMLDecl.new('1.1', 'utf-8')

          testsuites = doc.add_element('testsuites')
          suites.each do |suite, error_reports|
            add_tests_to(testsuites, suite, error_reports)
          end

          doc
        end

        def format_document(doc, io)
          formatter = REXML::Formatters::Pretty.new
          formatter.write(doc, io)
          io << "\n"
        end

        def add_tests_to(testsuites, suite, error_reports)
          testsuite = testsuites.add_element(
            'testsuite',
            'name' => suite,
            'filepath' => Minitest::Queue.relative_path(error_reports.first.test_file),
            'tests' => error_reports.count,
          )

          error_reports.each do |error_report|
            attributes = {
              'name' => error_report.test_name,
              'classname' => error_report.test_suite,
            }
            attributes['lineno'] = error_report.test_line

            testcase = testsuite.add_element('testcase', attributes)
            add_xml_message_for(testcase, error_report)
          rescue REXML::ParseException, RuntimeError => error
            puts error
          end
        end

        def add_xml_message_for(testcase, error_report)
          failure = testcase.add_element('failure', 'type' => error_report.error_class, 'message' => truncate_message(error_report.to_s))
          failure.add_text(REXML::CData.new(message_for(error_report)))
        end

        def truncate_message(message)
          message.lines.first.chomp.gsub(/\e\[[^m]+m/, '')
        end

        def project_root_path_matcher
          @project_root_path_matcher ||= %r{(?<=\s)#{Regexp.escape(Minitest::Queue.project_root)}/}
        end

        def message_for(error_report)
          suite = error_report.test_suite
          name = error_report.test_name
          error = error_report.to_s

          message_with_relative_paths = error.gsub(project_root_path_matcher, '')
          "\nFailure:\n#{name}(#{suite}) [#{Minitest::Queue.relative_path(error_report.test_file)}]:\n#{message_with_relative_paths}\n"
        end
      end

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

      APPLICATION_ERROR_EXIT_CODE = 42
      TIMED_OUT_EXIT_CODE = 43
      TOO_MANY_FAILED_TESTS_EXIT_CODE = 44
      WORKERS_DIED_EXIT_CODE = 45
      SUCCESS_EXIT_CODE = 0
      TEST_FAILURE_EXIT_CODE = 1

      def report
        exit_code = TEST_FAILURE_EXIT_CODE

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

          exit_code = TIMED_OUT_EXIT_CODE
        elsif supervisor.time_left_with_no_workers.to_i <= 0
          puts red("All workers died.")
          exit_code = WORKERS_DIED_EXIT_CODE
        elsif supervisor.max_test_failed?
          puts red("Encountered too many failed tests. Test run was ended early.")
          exit_code = TOO_MANY_FAILED_TESTS_EXIT_CODE
        end

        puts

        errors = error_reports
        puts errors

        build.worker_errors.to_a.sort.each do |worker_id, error|
          puts red("Worker #{worker_id } crashed")
          puts error
          puts ""
          exit_code = APPLICATION_ERROR_EXIT_CODE
        end

        success? ? SUCCESS_EXIT_CODE : exit_code
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
        File.open(file, 'w') do |f|
          JSON.dump(error_reports.map(&:to_h), f)
        end
        xml_file = File.join(File.dirname(file), "#{File.basename(file, File.extname(file))}.xml")
        JUnitReporter.new(xml_file, error_reports).write
      end

      def write_flaky_tests_file(file)
        File.open(file, 'w') do |f|
          JSON.dump(flaky_reports, f)
        end
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
