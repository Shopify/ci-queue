# frozen_string_literal: true
require 'rspec/queue/failure_formatter'
require 'rspec/queue/error_report'

module RSpec
  module Queue
    class BuildStatusRecorder
      ::RSpec::Core::Formatters.register self, :example_passed, :example_failed

      class << self
        attr_accessor :build
        attr_accessor :failure_formatter
      end
      self.failure_formatter = FailureFormatter

      def initialize(*)
      end

      def example_passed(notification)
        example = notification.example
        build.record_success(example.id)
      end

      def example_failed(notification)
        example = notification.example
        build.record_error(example.id, dump(notification))
      end

      private

      def dump(notification)
        ErrorReport.new(self.class.failure_formatter.new(notification).to_h).dump
      end

      def build
        self.class.build
      end
    end
  end
end
