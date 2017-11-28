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

    SuiteNotFound = Class.new(StandardError)

    def loaded_tests
      Minitest::Test.runnables.flat_map do |suite|
        suite.runnable_methods.map do |method|
          "#{suite}##{method}"
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
      runnable_classes = Minitest::Runnable.runnables.map { |s| [s.name, s] }.to_h

      queue.poll do |test_name|
        class_name, method_name = test_name.split("#".freeze, 2)

        if klass = runnable_classes[class_name]
          result = Minitest.run_one_method(klass, method_name)
          failed = !(result.passed? || result.skipped?)
          if failed && queue.requeue(test_name)
            result.requeue!
            reporter.record(result)
          elsif queue.acknowledge(test_name) || !failed
            # If the test was already acknowledged by another worker (we timed out)
            # Then we only record it if it is successful.
            reporter.record(result)
          end
        else
          raise SuiteNotFound, "Couldn't find suite matching: #{test_name}"
        end
      end
    end
  end
end

MiniTest.singleton_class.prepend(MiniTest::Queue)
MiniTest::Test.prepend(MiniTest::Requeueing)
