# frozen_string_literal: true

module Minitest
  module Queue
    class BuildStatusRecorder < Minitest::Reporter
      include Minitest::Reporters::BaseReporterShim

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

      attr_accessor :failures, :errors, :skips, :requeues, :assertions, :total_time

      def initialize(build:, **options)
        super(options)

        @build = build
        self.failures = 0
        self.errors = 0
        self.skips = 0
        self.requeues = 0
        self.total_time = 0.0
        self.assertions = 0
      end

      def report
        # noop
      end

      def record(result)
        self.total_time += result.time
        self.assertions += result.assertions

        if result.requeued?
          self.requeues += 1
        elsif result.skipped?
          self.skips += 1
        elsif result.error?
          self.errors += 1
        elsif result.failure
          self.failures += 1
        end

        stats = COUNTERS.zip(COUNTERS.map { |c| send(c) }).to_h
        if (result.failure || result.error?) && !result.skipped?
          build.record_error("#{result.klass}##{result.name}", dump(result), stats: stats)
        else
          build.record_success("#{result.klass}##{result.name}", stats: stats)
        end
      end

      private

      def dump(result)
        ErrorReport.new(self.class.failure_formatter.new(result).to_h).dump
      end

      attr_reader :build
    end
  end
end
