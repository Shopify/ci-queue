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
          attr_accessor :coder

          def load(payload)
            new(coder.load(payload))
          end
        end

        self.coder = Marshal

        begin
          require 'snappy'
          require 'msgpack'
          require 'stringio'

          module SnappyPack
            extend self

            MSGPACK = MessagePack::Factory.new
            MSGPACK.register_type(0x00, Symbol)

            def load(payload)
              io = StringIO.new(Snappy.inflate(payload))
              MSGPACK.unpacker(io).unpack
            end

            def dump(object)
              io = StringIO.new
              packer = MSGPACK.packer(io)
              packer.pack(object)
              packer.flush
              io.rewind
              Snappy.deflate(io.string).force_encoding(Encoding::UTF_8)
            end
          end

          self.coder = SnappyPack
        rescue LoadError
        end

        def initialize(data)
          @data = data
        end

        def dump
          self.class.coder.dump(@data)
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
        def initialize(build:, **options)
          @build = build
          super(options)
        end

        def completed?
          build.queue_exhausted?
        end

        def error_reports
          build.error_reports.sort_by(&:first).map { |k, v| Error.load(v) }
        end

        private

        attr_reader :build
      end

      class Summary < Base
        include ::CI::Queue::OutputHelpers

        def report
          puts aggregates
          errors = error_reports
          puts errors

          errors.empty?
        end

        def success?
          errors == 0 && failures == 0
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

        def progress
          build.progress
        end

        private

        def aggregates
          success = failures.zero? && errors.zero?
          failures_count = "#{failures} failures, #{errors} errors,"

          step([
            'Ran %d tests, %d assertions,' % [progress, assertions],
            success ? green(failures_count) : red(failures_count),
            yellow("#{skips} skips, #{requeues} requeues"),
            'in %.2fs (aggregated)' % total_time,
          ].join(' '), collapsed: success)
        end

        def fetch_summary
          @summary ||= build.fetch_stats(COUNTERS)
        end
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
          Error.new(RedisReporter.failure_formatter.new(test).to_h).dump
        end

        attr_reader :aggregates
      end
    end
  end
end
