require 'minitest'
gem 'minitest-reporters', '~> 1.1'
require 'minitest/reporters'

require 'minitest/queue/failure_formatter'
require 'minitest/queue/error_report'
require 'minitest/queue/local_requeue_reporter'
require 'minitest/queue/build_status_recorder'
require 'minitest/queue/build_status_reporter'
require 'minitest/queue/order_reporter'
require 'minitest/queue/junit_reporter'

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
      "Skipped"
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

      def run
        Minitest.run_one_method(@runnable, @method_name)
      end

      def flaky?
        Minitest.queue.flaky?(self)
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
        prepend_and_append_to_queue(*args) do
          run_from_queue(*args)
        end

        if queue.config.circuit_breaker.open?
          STDERR.puts "This worker is exiting early because it encountered too many consecutive test failures, probably because of some corrupted state."
        end
      else
        super
      end
    end

    def run_from_queue(reporter, *)
      queue.poll do |example|
        result = example.run
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

        if failed && queue.requeue(example)
          result.requeue!
          reporter.record(result)
        elsif queue.acknowledge(example) || !failed
          # If the test was already acknowledged by another worker (we timed out)
          # Then we only record it if it is successful.
          reporter.record(result)
        end
      end
    end

    def prepend_and_append_to_queue(reporter, *)
      file_path = ENV['APPEND_PREPEND_LIST_PATH']
      tests = []
      tests = File.read(file_path).lines.map(&:chomp) if !file_path.nil? && File.exist?(file_path)
      tests = tests.map do |test|
        queue.index.fetch(test)
      rescue KeyError
        nil
      end.compact

      run_tests_from_file(tests, reporter)
      yield
      run_tests_from_file(tests, reporter)
    end

    def run_tests_from_file(tests, reporter)
      tests.each do |test|
        result = test.run
        reporter.record(result)
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
