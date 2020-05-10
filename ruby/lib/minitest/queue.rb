# frozen_string_literal: true
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
    end
  end
end

Minitest.singleton_class.prepend(Minitest::Queue)
Minitest::Result.prepend(Minitest::Requeueing)
Minitest::Result.prepend(Minitest::Flakiness)
