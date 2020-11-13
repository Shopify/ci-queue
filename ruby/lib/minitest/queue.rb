# frozen_string_literal: true
require 'shellwords'
require 'minitest'
require 'minitest/reporters'

require 'minitest/queue/failure_formatter'
require 'minitest/queue/error_report'
require 'minitest/queue/local_requeue_reporter'
require 'minitest/queue/build_status_recorder'
require 'minitest/queue/build_status_reporter'
require 'minitest/queue/order_reporter'
require 'minitest/queue/junit_reporter'
require 'minitest/queue/test_data_reporter'
require 'minitest/queue/grind_recorder'
require 'minitest/queue/grind_reporter'
require 'minitest/queue/test_time_recorder'
require 'minitest/queue/test_time_reporter'

module Minitest
  class Requeue < Skip
    attr_reader :failure

    def initialize(failure)
      super()
      @failure = failure
    end

    def result_label
      "Requeued"
    end

    def backtrace
      failure.backtrace
    end

    def error
      failure.error
    end

    def message
      failure.message
    end
  end

  class Flaked < Skip
    attr_reader :failure

    def initialize(failure)
      super()
      @failure = failure
    end

    def result_label
      "Flaked"
    end

    def backtrace
      failure.backtrace
    end

    def error
      failure.error
    end

    def message
      failure.message
    end
  end

  module Requeueing
    # Make requeues acts as skips for reporters not aware of the difference.
    def skipped?
      super || requeued?
    end

    def requeued?
      Requeue === failure
    end

    def requeue!
      self.failures.unshift(Requeue.new(self.failures.shift))
    end
  end

  module Flakiness
    # Make failed flaky tests acts as skips for reporters not aware of the difference.
    def skipped?
      super || flaked?
    end

    def flaked?
      @flaky ||= false
      !!((Flaked === failure) || @flaky)
    end

    def mark_as_flaked!
      if passed?
        @flaky = true
      else
        self.failures.unshift(Flaked.new(self.failures.shift))
      end
    end
  end

  module Queue
    TimeoutError = Class.new(StandardError)

    attr_writer :run_command_formatter, :project_root

    def run_command_formatter
      @run_command_formatter ||= if defined?(Rails) && defined?(Rails::TestUnitRailtie)
        RAILS_RUN_COMMAND_FORMATTER
      else
        DEFAULT_RUN_COMMAND_FORMATTER
      end
    end

    DEFAULT_RUN_COMMAND_FORMATTER = lambda do |runnable|
      filename = Minitest::Queue.relative_path(runnable.source_location[0])
      identifier = "#{runnable.klass}##{runnable.name}"
      ['bundle', 'exec', 'ruby', '-Ilib:test', filename, '-n', identifier]
    end

    RAILS_RUN_COMMAND_FORMATTER = lambda do |runnable|
      filename = Minitest::Queue.relative_path(runnable.source_location[0])
      lineno = runnable.source_location[1]
      ['bin/rails', 'test', "#{filename}:#{lineno}"]
    end

    def run_command_for_runnable(runnable)
      command = run_command_formatter.call(runnable)
      if command.is_a?(Array)
        Shellwords.join(command)
      else
        command
      end
    end

    def self.project_root
      @project_root ||= Dir.pwd
    end

    def self.relative_path(path, root: project_root)
      Pathname(path).relative_path_from(Pathname(root)).to_s
    rescue ArgumentError
      path
    end

    class SingleExample

      def initialize(runnable, method_name)
        @runnable = runnable
        @method_name = method_name
      end

      def id
        @id ||= "#{@runnable}##{@method_name}"
      end

      def <=>(other)
        id <=> other.id
      end

      def build_result(failures = [])
        example = @runnable.new(@method_name)
        result = Minitest::Result.new(example.name)
        result.klass      = example.class.name
        result.failures   = failures
        result.time       = 30

        result.source_location = example.method(example.name).source_location rescue ["unknown", -1]
        result
      end

      def run
        Minitest.run_one_method(@runnable, @method_name)
      end

      def flaky?
        Minitest.queue.flaky?(self)
      end
    end

    class PipeQueue
      def initialize
        @read_io, @write_io = IO.pipe(Encoding::BINARY, Encoding::BINARY, binmode: true)
        @write_io.set_encoding(Encoding::BINARY)
      end

      def push(object)
        serialized_object = Marshal.dump(object)
        write_io.write([serialized_object.bytesize, serialized_object].pack('NA*'), encoding: 'BINARY')
      end

      def pop(timeout: nil, max_bytes: 1)
        Marshal.load(pop_bytes(timeout: timeout, max_bytes: payload_length(timeout: timeout)))
      end

      private

      attr_reader :deliminiter, :read_io, :write_io

      def payload_length(timeout:)
        pop_bytes(timeout: timeout, max_bytes: 4).unpack('N').pop
      end

      def pop_bytes(timeout:, max_bytes:)
        loop_with_buffer do |buffer|
          payload = read_io.read_nonblock(max_bytes, exception: false)

          if payload == :wait_readable
            wait_with_timeout(timeout: timeout)
          else
            buffer << payload
            max_bytes -= payload.bytesize
            break buffer if max_bytes <= 0
          end
        end
      end

      def loop_with_buffer
        ''.b.tap do |buffer|
          loop do
            yield buffer
          end
        end
      end

      def wait_with_timeout(timeout:)
        return if IO.select([read_io], nil, nil, timeout)

        raise TimeoutError.new("Did not complete in the allocated time.")
      end
    end

    class Executor
      def run(example, timeout: nil)
        example.run
      end

      def reset; end

      def teardown; end
    end

    class ForkingExecutor
      def run(example, timeout: nil)
        reset_sandbox_on_timeout(example) do
          sandbox.push(example)
          sandbox.pop(timeout: timeout)
        end
      end

      def teardown
        return unless sandbox

        sandbox.teardown
      end

      private

      attr_reader :tests_to_execute, :test_results, :pid

      def sandbox
        @sandbox ||= TestSandbox.new
      end

      def reset_sandbox_on_timeout(example)
        yield
      rescue TimeoutError => error
        p "Resetting sandbox!"
        sandbox.kill!
        @sandbox = nil
        error.set_backtrace([])
        example.build_result([UnexpectedError.new(error)])
      end
    end

    class TestSandbox
      def initialize
        @tests_to_execute = PipeQueue.new
        @test_results = PipeQueue.new
        @worker_pid = start_worker
      end

      def push(example)
        tests_to_execute.push(example)
      end

      def pop(timeout:)
        test_results.pop(timeout: timeout)
      end

      def kill!
        Process.kill('KILL', worker_pid)
      rescue SystemCallError
        false
      end

      def teardown
        tests_to_execute.push(:shutdown)
      end

      private

      attr_reader :worker_pid, :tests_to_execute, :test_results

      def start_worker
        Process.fork do
          loop do
            case (example = tests_to_execute.pop)
            when :shutdown
              break
            else
              puts 'Running test'
              test_results.push(example.run)
            end
          end
        end
      end
    end

    attr_reader :queue

    def queue=(queue)
      @queue = queue
    end

    def queue_reporters=(reporters)
      @queue_reporters ||= []
      Reporters.use!(((Reporters.reporters || []) - @queue_reporters) + reporters)
      Minitest.backtrace_filter.add_filter(%r{exe/minitest-queue|lib/ci/queue/})
      @queue_reporters = reporters
    end

    def loaded_tests
      Minitest::Test.runnables.flat_map do |runnable|
        runnable.runnable_methods.map do |method_name|
          SingleExample.new(runnable, method_name)
        end
      end
    end

    def __run(*args)
      if queue
        run_from_queue(*args)

        if queue.config.circuit_breakers.any?(&:open?)
          STDERR.puts queue.config.circuit_breakers.map(&:message).join(' ').strip
        end

        if queue.max_test_failed?
          STDERR.puts 'This worker is exiting early because too many failed tests were encountered.'
        end
      else
        super
      end
    end

    def run_from_queue(reporter, *)
      queue.poll do |example|
        result = executor.run(example, timeout: queue.config.timeout + 90)
        failed = !(result.passed? || result.skipped?)

        if example.flaky?
          result.mark_as_flaked!
          failed = false
        end

        if failed
          queue.report_failure!
        else
          queue.report_success!
        end

        requeued = false
        if failed && CI::Queue.requeueable?(result) && queue.requeue(example)
          requeued = true
          result.requeue!
          reporter.record(result)
        elsif queue.acknowledge(example) || !failed
          # If the test was already acknowledged by another worker (we timed out)
          # Then we only record it if it is successful.
          reporter.record(result)
        end

        if !requeued && failed
          queue.increment_test_failed
        end
      end
    ensure
      executor.teardown
    end

    def executor
      @executor ||= if queue.config.should_fork
        ForkingExecutor.new
      else
        Executor.new
      end
    end
  end
end

MiniTest.singleton_class.prepend(MiniTest::Queue)
if defined? MiniTest::Result
  MiniTest::Result.prepend(MiniTest::Requeueing)
  MiniTest::Result.prepend(MiniTest::Flakiness)
else
  MiniTest::Test.prepend(MiniTest::Requeueing)
  MiniTest::Test.prepend(MiniTest::Flakiness)

  module MinitestBackwardCompatibility
    def source_location
      method(name).source_location
    end

    def klass
      self.class.name
    end
  end
  MiniTest::Test.prepend(MinitestBackwardCompatibility)
end
