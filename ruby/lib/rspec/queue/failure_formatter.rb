# frozen_string_literal: true
require 'delegate'
require 'ci/queue/output_helpers'

module RSpec
  module Queue
    class FailureFormatter < SimpleDelegator
      include ::CI::Queue::OutputHelpers

      def initialize(notification)
        @notification = notification
        super
      end

      def to_s
        [
          @notification.fully_formatted(nil),
          colorized_rerun_command(@notification.example)
        ].join("\n")
      end

      def to_h
        example = @notification.example
        {
          test_file: example.file_path,
          test_line: example.metadata[:line_number],
          test_and_module_name: example.id,
          test_name: example.description,
          test_suite: example.example_group.description,
          error_class: @notification.exception.class.name,
          output: to_s,
        }
      end

      private

      attr_reader :notification

      def colorized_rerun_command(example, colorizer=::RSpec::Core::Formatters::ConsoleCodes)
        colorizer.wrap("rspec #{example.location_rerun_argument}", RSpec.configuration.failure_color) + " " +
        colorizer.wrap("# #{example.full_description}", RSpec.configuration.detail_color)
      end
    end
  end
end