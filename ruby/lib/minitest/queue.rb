require 'minitest'

gem 'minitest-reporters', '~> 1.1'
require 'minitest/reporters'

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
    end

    attr_reader :queue

    def queue=(queue)
      @queue = queue
      if queue.respond_to?(:minitest_reporters)
        self.queue_reporters = queue.minitest_reporters
      else
        self.queue_reporters = []
      end
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
      else
        super
      end
    end

    def run_from_queue(reporter, *)
      queue.poll do |example|
        result = example.run
        failed = !(result.passed? || result.skipped?)
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
  end
end

MiniTest.singleton_class.prepend(MiniTest::Queue)
MiniTest::Test.prepend(MiniTest::Requeueing)
