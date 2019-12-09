# frozen_string_literal: true
require 'delegate'
require 'ansi'

module Minitest
  module Queue
    class FailureFormatter < SimpleDelegator
      include ANSI::Code

      def initialize(test)
        @test = test
        super
      end

      def to_s
        [
          header,
          body,
          "\n"
        ].flatten.compact.join("\n")
      end

      def to_h
        test_file, test_line = test.source_location
        {
          test_file: test_file,
          test_line: test_line,
          test_and_module_name: "#{test.klass}##{test.name}",
          test_name: test.name,
          output: to_s,
        }
      end

      private

      attr_reader :test

      def header
        "#{red(status)} #{test.klass}##{test.name}"
      end

      def status
        if test.error?
          'ERROR'
        elsif test.failure
          'FAIL'
        else
          raise ArgumentError, "Couldn't infer test status"
        end
      end

      def body
        error = test.failure
        message = if error.is_a?(MiniTest::UnexpectedError)
          "#{error.exception.class}: #{error.exception.message}"
        else
          error.exception.message
        end

        backtrace = Minitest.filter_backtrace(error.backtrace).map { |line| '    ' + relativize(line) }
        [yellow(message), *backtrace].join("\n")
      end

      def relativize(trace_line)
        trace_line.sub(/\A#{Regexp.escape("#{Dir.pwd}/")}/, '')
      end
    end
  end
end
