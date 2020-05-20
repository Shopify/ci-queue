# frozen_string_literal: true

require 'minitest/reporters'
require 'rexml/document'
require 'fileutils'

module Minitest
  module Queue
    class JUnitReporter < Minitest::Reporters::BaseReporter
      def initialize(report_path = 'log/junit.xml', options = {})
        super({})
        @report_path = File.absolute_path(report_path)
        @base_path = options[:base_path] || Dir.pwd
      end

      def generate_document
        suites = tests.group_by { |test| test.klass }

        doc = REXML::Document.new(nil, {
          :prologue_quote => :quote,
          :attribute_quote => :quote,
        })
        doc << REXML::XMLDecl.new('1.1', 'utf-8')

        testsuites = doc.add_element('testsuites')
        suites.each do |suite, tests|
          add_tests_to(testsuites, suite, tests)
        end
        doc
      end

      def format_document(doc, io)
        formatter = REXML::Formatters::Pretty.new
        formatter.write(doc, io)
        io << "\n"
      end

      def report
        super

        FileUtils.mkdir_p(File.dirname(@report_path))
        File.open(@report_path, 'w+') do |file|
          format_document(generate_document, file)
        end
      end

      private

      def add_tests_to(testsuites, suite, tests)
        suite_result = analyze_suite(tests)
        relative_path = location_for_runnable(tests.first) || '<unknown>'

        testsuite = testsuites.add_element(
          'testsuite',
          'name' => suite,
          'filepath' => relative_path,
          'skipped' => suite_result[:skip_count],
          'failures' => suite_result[:fail_count],
          'errors' => suite_result[:error_count],
          'tests' => suite_result[:test_count],
          'assertions' => suite_result[:assertion_count],
          'time' => suite_result[:time],
        )

        tests.each do |test|
          lineno = tests.first.source_location.last
          attributes = {
            'name' => test.name,
            'classname' => suite,
            'assertions' => test.assertions,
            'time' => test.time,
            'flaky_test' => test.flaked?,
            'run-command' => Minitest.run_command_for_runnable(test),
          }
          attributes['lineno'] = lineno if lineno != -1

          testcase = testsuite.add_element('testcase', attributes)
          add_xml_message_for(testcase, test) unless test.passed?
        end
      end

      def add_xml_message_for(testcase, test)
        failure = test.failure
        if test.skipped? && !test.flaked?
          testcase.add_element('skipped', 'type' => failure.error.class.name)
        elsif test.error?
          error = testcase.add_element('error', 'type' => failure.error.class.name, 'message' => truncate_message(failure.message))
          error.add_text(REXML::CData.new(message_for(test)))
        elsif failure
          failure = testcase.add_element('failure', 'type' => failure.error.class.name, 'message' => truncate_message(failure.message))
          failure.add_text(REXML::CData.new(message_for(test)))
        end
      end

      def truncate_message(message)
        message.lines.first.chomp.gsub(/\e\[[^m]+m/, '')
      end

      def project_root_path_matcher
        @project_root_path_matcher ||= %r{(?<=\s)#{Regexp.escape(Minitest::Queue.project_root)}/}
      end

      def message_for(test)
        suite = test.klass
        name = test.name
        error = test.failure

        message_with_relative_paths = error.message.gsub(project_root_path_matcher, '')
        if test.passed?
          nil
        elsif test.skipped?
          "\nSkipped:\n#{name}(#{suite}) [#{location_for_runnable(test)}]:\n#{message_with_relative_paths}\n"
        elsif test.failure
          "\nFailure:\n#{name}(#{suite}) [#{location_for_runnable(test)}]:\n#{message_with_relative_paths}\n"
        elsif test.error?
          "\nError:\n#{name}(#{suite}) [#{location_for_runnable(test)}]:\n#{message_with_relative_paths}\n"
        end
      end

      def location_for_runnable(runnable)
        if runnable.source_location.first == 'unknown'
          nil
        else
          Minitest::Queue.relative_path(runnable.source_location.first)
        end
      end

      def analyze_suite(tests)
        result = Hash.new(0)
        result[:time] = 0
        tests.each do |test|
          result[:"#{result(test)}_count"] += 1
          result[:assertion_count] += test.assertions
          result[:test_count] += 1
          result[:time] += test.time
        end
        result
      end
    end
  end
end
