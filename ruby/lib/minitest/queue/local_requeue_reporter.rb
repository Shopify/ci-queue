# frozen_string_literal: true
require 'ci/queue/output_helpers'
require 'minitest/reporters'

module Minitest
  module Queue
    class LocalRequeueReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers
      attr_accessor :requeues

      def initialize(*)
        self.requeues = 0
        super
      end

      def report
        self.requeues = results.count(&:requeued?)
        super
        print_report
      end

      private

      def print_report
        reopen_previous_step if failures > 0 || errors > 0
        success = failures.zero? && errors.zero?
        failures_count = "#{failures} failures, #{errors} errors,"
        step [
          'Ran %d tests, %d assertions,' % [count, assertions],
          success ? green(failures_count) : red(failures_count),
          yellow("#{skips} skips, #{requeues} requeues"),
          'in %.2fs' % total_time,
        ].join(' ')
      end

      def message_for(test)
        e = test.failure

        if test.requeued?
          "Requeued:\n#{test.klass}##{test.name} [#{location(e)}]:\n#{e.message}"
        else
          super
        end
      end

      def result_line
        "#{super}, #{requeues} requeues"
      end
    end
  end
end
