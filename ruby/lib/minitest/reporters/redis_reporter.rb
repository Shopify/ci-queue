require 'minitest/reporters'

module Minitest
  module Reporters
    module RedisReporter
      include ANSI::Code

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

      class Base < BaseReporter
        def initialize(build:, **options)
          @build = build
          super(options)
        end

        def completed?
          build.queue_exhausted?
        end

        def error_reports
          build.error_reports.sort_by(&:first).map { |k, v| ErrorReport.load(v) }
        end

        private

      end

      class Summary < Base
      end

      class Worker < Base
        attr_accessor :requeues

        def initialize(*)
          super
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
          if test.requeued?
            self.requeues += 1
          elsif test.skipped?
            self.skips += 1
          elsif test.error?
            self.errors += 1
          elsif test.failure
            self.failures += 1
          end


          stats = COUNTERS.zip(COUNTERS.map { |c| send(c) })
          if (test.failure || test.error?) && !test.skipped?
            build.record_error("#{test.klass}##{test.name}", dump(test), stats: stats)
          else
            build.record_success("#{test.klass}##{test.name}", stats: stats)
          end
        end

        private

        def dump(test)
          ErrorReport.new(RedisReporter.failure_formatter.new(test).to_h).dump
        end

        attr_reader :aggregates
      end
    end
  end
end
