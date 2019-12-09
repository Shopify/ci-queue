# frozen_string_literal: true
module Minitest
  module Queue
    class TestTimeRecorder < Minitest::Reporters::BaseReporter
      def initialize(build:, **options)
        super(options)
        @build = build
      end

      def record(test)
        return unless test.passed?
        test_duration_in_milliseconds = test.time * 1000
        @build.record(test.name, test_duration_in_milliseconds)
      end
    end
  end
end
