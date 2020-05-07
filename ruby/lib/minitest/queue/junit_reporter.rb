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

        doc = REXML::Document.new
        testsuites = doc.add_element('testsuites')
        suites.each do |suite, tests|
          add_tests_to(testsuites, suite, tests)
        end
        doc
      end

      def format_document(doc, io)
        io << "<?xml version='1.0' encoding='UTF-8'?>\n"
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
        relative_path = if tests.first.source_location.first == 'unknown'
          Pathname.new('')
        else
          file_path = Pathname.new(tests.first.source_location.first)
          if file_path.relative?
            file_path
          else
            base_path = Pathname.new(@base_path)
            file_path.relative_path_from(base_path)
          end
        end

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
            'flaky_test' => test.flaked?
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

      def message_for(test)
        suite = test.klass
        name = test.name
        error = test.failure

        if test.passed?
          nil
        elsif test.skipped?
          "\nSkipped:\n#{name}(#{suite}) [#{location(error)}]:\n#{error.message}\n"
        elsif test.failure
          "\nFailure:\n#{name}(#{suite}) [#{location(error)}]:\n#{error.message}\n"
        elsif test.error?
          "\nError:\n#{name}(#{suite}) [#{location(error)}]:\n#{error.message}\n"
        end
      end

      def location(exception)
        last_before_assertion = ''
        (exception.backtrace || []).reverse_each do |s|
          break if s =~ /in .(assert|refute|flunk|pass|fail|raise|must|wont)/
          last_before_assertion = s
        end
        last_before_assertion.sub(/:in .*$/, '')
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
