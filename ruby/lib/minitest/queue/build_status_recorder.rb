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
        ignored
        total_time
      ).freeze

      class << self
        attr_accessor :failure_formatter
      end
      self.failure_formatter = FailureFormatter

      attr_accessor :requeues, :ignored

      def initialize(build:, **options)
        super(options)

        @build = build
        self.failures = 0
        self.errors = 0
        self.skips = 0
        self.requeues = 0
        self.ignored = 0
      end

      def report
        # noop
      end

      def record(test)
        super

        self.total_time = Minitest.clock_time - start_time

        # Determine what type of result this is and record it
        test_id = "#{test.klass}##{test.name}"
        acknowledged = if (test.failure || test.error?) && !test.skipped?
          build.record_error(test_id, dump(test))
        elsif test.requeued?
          build.record_requeue(test_id)
        else
          build.record_success(test_id, skip_flaky_record: test.skipped?)
        end

        # Only increment counters if the test was actually acknowledged
        if acknowledged
          if test.requeued?
            self.requeues += 1
          elsif test.skipped?
            self.skips += 1
          elsif test.error?
            self.errors += 1
          elsif test.failure
            self.failures += 1
          end
        else
          # Test was not acknowledged (already processed), mark as ignored
          self.ignored += 1
        end

        # Record stats after incrementing counters
        stats = COUNTERS.zip(COUNTERS.map { |c| send(c) }).to_h
        build.record_stats(stats)
      end

      private

      def dump(test)
        ErrorReport.new(self.class.failure_formatter.new(test).to_h).dump
      end

      attr_reader :build
    end
  end
end
