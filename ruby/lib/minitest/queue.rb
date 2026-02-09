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

  module WithTimestamps
    attr_accessor :start_timestamp, :finish_timestamp
  end

  module ResultMetadata
    attr_accessor :queue_id, :queue_entry
  end

  module Queue
    extend ::CI::Queue::OutputHelpers
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
    rescue ArgumentError, TypeError
      path
    end

    class << self
      def queue
        Minitest.queue
      end

      def run(reporter, *)
        rescue_run_errors do
          begin
            queue.poll do |example|
              result = queue.with_heartbeat(example.queue_entry) do
                example.run
              end

              handle_test_result(reporter, example, result)
            end

            report_load_stats(queue)
          ensure
            store_worker_profile(queue)
          end
          queue.stop_heartbeat!
        end
      end

      def handle_test_result(reporter, example, result)
        if result.respond_to?(:queue_id=)
          result.queue_id = example.id
          result.queue_entry = example.queue_entry if result.respond_to?(:queue_entry=)
        end

        failed = !(result.passed? || result.skipped?)

        if example.flaky?
          result.mark_as_flaked!
          failed = false
        end

        if failed && queue.config.failing_test && queue.config.failing_test != example.id
          # When we do a bisect, we don't care about the result other than the test we're running the bisect on
          result.mark_as_flaked!
          failed = false
        elsif failed
          queue.report_failure!
        else
          queue.report_success!
        end

        if failed && CI::Queue.requeueable?(result) && queue.requeue(example)
          result.requeue!
        end
        reporter.record(result)
      end

      private

      def report_load_stats(queue)
        return unless queue.respond_to?(:file_loader)
        return unless queue.respond_to?(:config) && queue.config.lazy_load

        loader = queue.file_loader
        return if loader.load_stats.empty?

        total_time = loader.total_load_time
        file_count = loader.load_stats.size
        average = file_count.zero? ? 0 : (total_time / file_count)

        puts
        puts "File loading stats:"
        puts "  Total time: #{total_time.round(2)}s"
        puts "  Files loaded: #{file_count}"
        puts "  Average: #{average.round(3)}s per file"

        slowest = loader.slowest_files(5)
        return if slowest.empty?

        puts "  Slowest files:"
        slowest.each do |file_path, duration|
          puts "    #{duration.round(3)}s - #{Minitest::Queue.relative_path(file_path)}"
        end
      end

      def store_worker_profile(queue)
        return unless queue.respond_to?(:config)
        config = queue.config

        run_start = Minitest::Queue::Runner.run_start
        return unless run_start

        run_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        profile = {
          'worker_id' => config.worker_id,
          'mode' => config.lazy_load ? 'lazy' : 'eager',
          'role' => queue.master? ? 'leader' : 'non-leader',
          'total_wall_clock' => (run_end - run_start).round(2),
        }

        first_test = queue.respond_to?(:first_reserve_at) ? queue.first_reserve_at : nil
        profile['time_to_first_test'] = (first_test - run_start).round(2) if first_test

        tests_run = queue.rescue_connection_errors { queue.send(:redis).llen(queue.send(:key, 'worker', config.worker_id, 'queue')) }
        profile['tests_run'] = tests_run.to_i if tests_run

        load_tests_duration = Minitest::Queue::Runner.load_tests_duration
        profile['load_tests_duration'] = load_tests_duration.round(2) if load_tests_duration

        if queue.respond_to?(:file_loader) && queue.file_loader.load_stats.any?
          loader = queue.file_loader
          profile['files_loaded'] = loader.load_stats.size
          profile['file_load_time'] = loader.total_load_time.round(2)
        end

        profile['total_files'] = Minitest::Queue::Runner.total_files if Minitest::Queue::Runner.total_files

        rss_kb = begin
          if File.exist?("/proc/#{Process.pid}/statm")
            pages = Integer(File.read("/proc/#{Process.pid}/statm").split[1])
            pages * 4
          else
            Integer(`ps -o rss= -p #{Process.pid}`.strip)
          end
        rescue
          nil
        end
        profile['memory_rss_kb'] = rss_kb if rss_kb

        queue.rescue_connection_errors do
          queue.build.record_worker_profile(profile)
        end
      rescue => e
        puts "WARNING: Failed to store worker profile: #{e.message}"
      end

      def rescue_run_errors(&block)
        block.call
      rescue Errno::EPIPE
        # This happens when the heartbeat process dies
        reopen_previous_step
        puts red("The heartbeat process died. This worker is exiting early.")
        exit!(41)
      rescue CI::Queue::Error => error
        reopen_previous_step
        puts red("#{error.class}: #{error.message}")
        error.backtrace.each do |frame|
          puts red(frame)
        end
        exit!(41)
      rescue => error
        reopen_previous_step
        Minitest.queue.report_worker_error(error)
        puts red("This worker exited because of an uncaught application error:")
        puts red("#{error.class}: #{error.message}")
        error.backtrace.each do |frame|
          puts red(frame)
        end
        exit!(42)
      end
    end

    class SingleExample
      attr_reader :runnable, :method_name

      def initialize(runnable, method_name)
        @runnable = runnable
        @method_name = method_name
      end

      def id
        @id ||= "#{@runnable}##{@method_name}".freeze
      end

      def queue_entry
        id
      end

      def <=>(other)
        id <=> other.id
      end

      def with_timestamps
        start_timestamp = current_timestamp
        result = yield
        result
      ensure
        if result
          result.start_timestamp = start_timestamp
          result.finish_timestamp = current_timestamp
        end
      end

      def run
        with_timestamps do
          Minitest.run_one_method(@runnable, @method_name)
        end
      end

      def flaky?
        Minitest.queue.flaky?(self)
      end

      def source_location
        @runnable.instance_method(@method_name).source_location
      rescue NameError, NoMethodError
        nil
      end

      private

      def current_timestamp
        CI::Queue.time_now.to_i
      end
    end

    class LazySingleExample
      attr_reader :class_name, :method_name, :file_path

      def initialize(class_name, method_name, file_path, loader:, resolver:, load_error: nil, queue_entry: nil)
        @class_name = class_name
        @method_name = method_name
        @file_path = file_path
        @loader = loader
        @resolver = resolver
        @load_error = load_error
        @queue_entry_override = queue_entry
        @runnable = nil
      end

      def id
        @id ||= "#{@class_name}##{@method_name}".freeze
      end

      def queue_entry
        @queue_entry ||= @queue_entry_override || CI::Queue::QueueEntry.format(id, file_path)
      end

      def <=>(other)
        id <=> other.id
      end

      RUNNABLE_METHODS_TRIGGERED = {} # :nodoc:

      def runnable
        @runnable ||= begin
          # Always ensure the test file is loaded via FileLoader, even if the
          # class already exists (e.g., autoloaded by Zeitwerk). Zeitwerk loads
          # the class but may not execute test-specific code like `include`
          # statements for helper modules or `run_all_with_flag` declarations.
          @loader.load_file(@file_path) if @file_path && @loader

          klass = @resolver.resolve(@class_name, file_path: @file_path, loader: @loader)
          unless RUNNABLE_METHODS_TRIGGERED[klass]
            klass.runnable_methods
            RUNNABLE_METHODS_TRIGGERED[klass] = true
          end

          klass
        end
      end

      def with_timestamps
        start_timestamp = current_timestamp
        result = yield
        result
      ensure
        if result
          result.start_timestamp = start_timestamp
          result.finish_timestamp = current_timestamp
        end
      end

      def run
        with_timestamps do
          begin
            return build_error_result(@load_error) if @load_error
            Minitest.run_one_method(runnable, @method_name)
          rescue StandardError, ScriptError => error
            build_error_result(error)
          end
        end
      end

      def flaky?
        Minitest.queue.flaky?(self)
      end

      def source_location
        return nil if @load_error

        runnable.instance_method(@method_name).source_location
      rescue NameError, NoMethodError, CI::Queue::FileLoadError, CI::Queue::ClassNotFoundError
        nil
      end

      def marshal_dump
        {
          'class_name' => @class_name,
          'method_name' => @method_name,
          'file_path' => @file_path,
          'load_error' => serialize_error(@load_error),
          'queue_entry' => @queue_entry_override,
        }
      end

      def marshal_load(payload)
        @class_name = payload['class_name']
        @method_name = payload['method_name']
        @file_path = payload['file_path']
        @load_error = deserialize_error(payload['load_error'])
        @queue_entry_override = payload['queue_entry']
        @loader = CI::Queue::FileLoader.new
        @resolver = CI::Queue::ClassResolver
        @runnable = nil
        @id = nil
        @queue_entry = nil
      end

      private

      def serialize_error(error)
        return nil unless error

        {
          'class' => error.class.name,
          'message' => error.message,
          'backtrace' => error.backtrace,
        }
      end

      def deserialize_error(payload)
        return nil unless payload

        message = "#{payload['class']}: #{payload['message']}"
        error = StandardError.new(message)
        error.set_backtrace(payload['backtrace']) if payload['backtrace']
        CI::Queue::FileLoadError.new(@file_path, error)
      end

      def build_error_result(error)
        result_class = defined?(Minitest::Result) ? Minitest::Result : Minitest::Test
        result = result_class.new(@method_name)
        result.klass = @class_name if result.respond_to?(:klass=)
        result.failures << Minitest::UnexpectedError.new(error)
        result
      end

      def current_timestamp
        CI::Queue.time_now.to_i
      end
    end

    attr_accessor :queue

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
        Queue.run(*args)

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
  end
end

Minitest.singleton_class.prepend(Minitest::Queue)
if defined? Minitest::Result
  Minitest::Result.prepend(Minitest::Requeueing)
  Minitest::Result.prepend(Minitest::Flakiness)
  Minitest::Result.prepend(Minitest::WithTimestamps)
  Minitest::Result.prepend(Minitest::ResultMetadata)
else
  Minitest::Test.prepend(Minitest::Requeueing)
  Minitest::Test.prepend(Minitest::Flakiness)
  Minitest::Test.prepend(Minitest::WithTimestamps)
  Minitest::Test.prepend(Minitest::ResultMetadata)

  module MinitestBackwardCompatibility
    def source_location
      method(name).source_location
    end

    def klass
      self.class.name
    end
  end
  Minitest::Test.prepend(MinitestBackwardCompatibility)
end
