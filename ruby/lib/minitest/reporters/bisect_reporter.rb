# frozen_string_literal: true

module Minitest
  module Reporters
    class BisectReporter < Minitest::Reporter
      include Minitest::Reporters::BaseReporterShim

      def start
        @failure_detected = false
      end

      def record(result)
        @failure_detected ||= !(result.passed? || result.skipped?)
        puts format("  %-63s %s", "#{result.class_name}##{result.name}", result_label(result))
      end

      def passed?
        !@failure_detected
      end

      private

      def result_label(result)
        if result.passed?
          'PASS'
        elsif result.skipped?
          'SKIP'
        elsif result.error?
          'ERROR'
        else
          'FAIL'
        end
      end
    end
  end
end
