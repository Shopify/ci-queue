require 'minitest/reporters'
require 'minitest/reporters/failure_formatter'

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

      class Error
        class << self
          def load(payload)
            Marshal.load(payload)
          end
        end

        def initialize(data)
          @data = data
        end

        def dump
          Marshal.dump(self)
        end

        def test_name
          @data[:test_name]
        end

        def test_and_module_name
          @data[:test_and_module_name]
        end

        def to_s
          output
        end

        def output
          @data[:output]
        end
      end

      class Base < BaseReporter
        def initialize(redis:, build_id:, **options)
          @redis = redis
          @key = "build:#{build_id}"
          super(options)
        end

        def total
          redis.get(key('total')).to_i
        end

        def processed
          redis.scard(key('processed')).to_i
        end

        def completed?
          total > 0 && total == processed
        end

        def error_reports
          redis.hgetall(key('error-reports')).sort_by(&:first).map { |k, v| Error.load(v) }
        end

        private

        attr_reader :redis

        def key(*args)
          [@key, *args].join(':')
        end
      end

      class Summary < Base
        include ANSI::Code

        def report(io: STDOUT)
          io.puts aggregates
          errors = error_reports
          io.puts errors

          errors.empty?
        end

        def record(*)
          raise NotImplementedError
        end

        def failures
          fetch_summary['failures'].to_i
        end

        def errors
          fetch_summary['errors'].to_i
        end

        def assertions
          fetch_summary['assertions'].to_i
        end

        def skips
          fetch_summary['skips'].to_i
        end

        def requeues
          fetch_summary['requeues'].to_i
        end

        def total_time
          fetch_summary['total_time'].to_f
        end

        private

        def aggregates
          success = failures.zero? && errors.zero?
          failures_count = "#{failures} failures, #{errors} errors,"

          [
            'Ran %d tests, %d assertions,' % [processed, assertions],
            success ? green(failures_count) : red(failures_count),
            yellow("#{skips} skips, #{requeues} requeues"),
            'in %.2fs (aggregated)' % total_time,
          ].join(' ')
        end

        def fetch_summary
          @summary ||= begin
            counts = redis.pipelined do
              COUNTERS.each { |c| redis.hgetall(key(c)) }
            end
            COUNTERS.zip(counts.map { |h| h.values.map(&:to_f).inject(:+).to_f }).to_h
          end
        end
      end

      class Worker < Base
        attr_accessor :requeues

        def initialize(worker_id:, **options)
          super
          @worker_id = worker_id
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

          redis.multi do
            if (test.failure || test.error?) && !test.skipped?
              redis.hset(key('error-reports'), "#{test.class}##{test.name}", dump(test))
            else
              redis.hdel(key('error-reports'), "#{test.class}##{test.name}")
            end
            COUNTERS.each do |counter|
              redis.hset(key(counter), worker_id, send(counter))
            end
          end
        end

        private

        def dump(test)
          Error.new(RedisReporter.failure_formatter.new(test).to_h).dump
        end

        attr_reader :worker_id, :aggregates
      end
    end
  end
end