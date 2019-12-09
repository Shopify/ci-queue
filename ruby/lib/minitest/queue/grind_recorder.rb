# frozen_string_literal: true
module Minitest
  module Queue
    class GrindRecorder < Minitest::Reporters::BaseReporter

      attr_accessor :test_count

      def self.counters
        @counters ||= {
          'failures' => 0,
          'errors' => 0,
          'skips' => 0,
          'test_count' => 0
        }
      end

      class << self
        attr_accessor :failure_formatter
      end
      self.failure_formatter = FailureFormatter

      def initialize(build:, **options)
        super(options)
        @build = build
      end

      def record(test)
        increment_counter(test)
        record_test(test)
      end

      private

      def record_test(test)
        stats = self.class.counters
        if (test.failure || test.error?) && !test.skipped?
          build.record_error(dump(test), stats: stats)
        else
          build.record_success(stats: stats)
        end
      end

      def increment_counter(test)
        if test.skipped?
          self.class.counters['skips'] += 1
        elsif test.error?
          self.class.counters['errors'] += 1
        elsif test.failure
          self.class.counters['failures'] += 1
        end
        self.class.counters['test_count'] += 1

        key = "count##{test.klass}##{test.name}"

        unless self.class.counters.key?(key)
          self.class.counters[key] = 0
        end
        self.class.counters[key] += 1
      end

      def dump(test)
        ErrorReport.new(self.class.failure_formatter.new(test).to_h).dump
      end

      attr_reader :build
    end
  end
end
