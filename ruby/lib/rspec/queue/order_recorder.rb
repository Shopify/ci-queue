# frozen_string_literal: true
require 'rspec/core/formatters/base_formatter'

module RSpec
  module Queue
    class OrderRecorder < ::RSpec::Core::Formatters::BaseFormatter
      ::RSpec::Core::Formatters.register self, :example_started

      def initialize(*)
        super
        output.sync = true
      end

      def example_started(notification)
        return if notification.is_a?(RSpec::Core::Notifications::SkippedExampleNotification)
        output.write("#{notification.example.id}\n")
      end
    end
  end
end
