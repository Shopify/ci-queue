# frozen_string_literal: true
module RSpec
  module Queue
    class BuildStatusRecorder
      ::RSpec::Core::Formatters.register self, :example_passed, :example_failed

      class << self
        attr_accessor :build
      end

      def initialize(*)
      end

      def example_passed(notification)
        example = notification.example
        build.record_success(example.id)
      end

      def example_failed(notification)
        example = notification.example
        build.record_error(example.id, [
          notification.fully_formatted(nil),
          colorized_rerun_command(example),
        ].join("\n"))
      end

      private

      def colorized_rerun_command(example, colorizer=::RSpec::Core::Formatters::ConsoleCodes)
        colorizer.wrap("rspec #{example.location_rerun_argument}", RSpec.configuration.failure_color) + " " +
        colorizer.wrap("# #{example.full_description}",   RSpec.configuration.detail_color)
      end

      def build
        self.class.build
      end
    end
  end
end
