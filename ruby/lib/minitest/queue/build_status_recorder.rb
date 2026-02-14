# frozen_string_literal: true
require 'minitest/reporters'

module Minitest
  module Queue
    class BuildStatusRecorder < Minitest::Reporters::BaseReporter
      COUNTERS = %w(
        assertions
        errors
        failures
        skips
        requeues
        total_time
      ).freeze

      class << self
        attr_accessor :failure_formatter
      end
      self.failure_formatter = FailureFormatter

      attr_accessor :requeues

      def initialize(build:, **options)
        super(options)

        @build = build
        self.failures = 0
        self.errors = 0
        self.skips = 0
        self.requeues = 0
      end

      def report
        # noop
      end

      def record(test)
        super

        self.total_time = Minitest.clock_time - start_time
        
        # Determine what type of result this is and record it
        test_id = "#{test.klass}##{test.name}"
        delta = delta_for(test)

        acknowledged = if (test.failure || test.error?) && !test.skipped?
          build.record_error(test_id, dump(test), stat_delta: delta)
        elsif test.requeued?
          build.record_requeue(test_id)
        else
          build.record_success(test_id, skip_flaky_record: test.skipped?)
        end

        if acknowledged
          if (test.failure || test.error?) && !test.skipped?
            test.error? ? self.errors += 1 : self.failures += 1
          elsif test.requeued?
            self.requeues += 1
          elsif test.skipped?
            self.skips += 1
          end
          # Apply delta to Redis (record_success returns true when ack'd or when we replaced a failure)
          build.record_stats_delta(delta)
        end
      end

      private

      def delta_for(test)
        h = { 'assertions' => (test.assertions || 0).to_i, 'errors' => 0, 'failures' => 0, 'skips' => 0, 'requeues' => 0, 'total_time' => test.time.to_f }
        if (test.failure || test.error?) && !test.skipped?
          test.error? ? h['errors'] = 1 : h['failures'] = 1
        elsif test.requeued?
          h['requeues'] = 1
        elsif test.skipped?
          h['skips'] = 1
        end
        h
      end

      def dump(test)
        ErrorReport.new(self.class.failure_formatter.new(test).to_h).dump
      end

      attr_reader :build
    end
  end
end
