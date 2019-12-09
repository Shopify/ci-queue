# frozen_string_literal: true
require 'fileutils'
require 'delegate'
require 'rspec/core'
require 'ci/queue'
require 'rspec/queue/build_status_recorder'
require 'rspec/queue/order_recorder'

module RSpec
  module Queue
    class << self
      def config
        @config ||= CI::Queue::Configuration.from_env(ENV)
      end
    end

    module RunnerHelpers
      private

      def queue_url
        configuration.queue_url || ENV['CI_QUEUE_URL']
      end

      def invalid_usage!(message)
        reopen_previous_step
        puts red(message)
        puts
        puts 'Please use --help for a listing of valid options'
        exit! 1 # exit! is required to avoid at_exit callback
      end

      def exit!(*)
        STDOUT.flush
        STDERR.flush
        super
      end

      def abort!(message)
        reopen_previous_step
        puts red(message)
        exit! 1 # exit! is required to avoid at_exit callback
      end
    end

    module ConfigurationExtension
      private

      def command
        'rspec' # trick rspec into enabling it's default behavior
      end
    end

    Core::Configuration.add_setting(:queue_url)
    Core::Configuration.prepend(ConfigurationExtension)

    module ConfigurationOptionsExtension
      attr_accessor :queue_url
    end
    Core::ConfigurationOptions.prepend(ConfigurationOptionsExtension)


    module ParserExtension
      private

      def parser(options)
        parser = super

        parser.separator("\n  **** Queue options ****\n\n")

        help = <<~EOS
          URL of the queue, e.g. redis://example.com.
          Defaults to $CI_QUEUE_URL if set.
        EOS
        parser.separator ""
        parser.on('--queue URL', *help) do |url|
          options[:queue_url] = url
        end

        help = <<~EOS
          Wait for all workers to complete and summarize the test failures.
        EOS
        parser.on('--report', *help) do |url|
          options[:report] = true
          options[:runner] = RSpec::Queue::ReportRunner.new
        end

        help = <<~EOS
          Replays a previous run in the same order.
        EOS
        parser.on('--retry', *help) do |url|
          STDERR.puts "Warning: The --retry flag is deprecated"
        end

        help = <<~EOS
          Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier.
          If the build is tried again, or another revision is built, this value must be different.
          It's automatically inferred on Buildkite, CircleCI and Travis.
        EOS
        parser.separator ""
        parser.on('--build BUILD_ID', *help) do |build_id|
          queue_config.build_id = build_id
        end

        help = <<~EOS
          Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites.
            Example: --namespace integration
        EOS
        parser.separator ""
        parser.on('--namespace NAMESPACE', *help) do |namespace|
          queue_config.namespace = namespace
        end

        help = <<~EOS
          Specify a timeout after which if a test haven't completed, it will be picked up by another worker.
          It is very important to set this vlaue higher than the slowest test in the suite, otherwise performance will be impacted.
          Defaults to 30 seconds.
        EOS
        parser.separator ""
        parser.on('--timeout TIMEOUT', *help) do |timeout|
          queue_config.timeout = Float(timeout)
        end

        help = <<~EOS
          A unique identifier for this worker, It must be consistent to allow retries.
          If not specified, retries won't be available.
          It's automatically inferred on Buildkite and CircleCI.
        EOS
        parser.separator ""
        parser.on('--worker WORKER_ID', *help) do |worker_id|
          queue_config.worker_id = worker_id
        end

        help = <<~EOS
          Defines how many time a single test can be requeued.
          Defaults to 0.
        EOS
        parser.separator ""
        parser.on('--max-requeues MAX', *help) do |max|
          queue_config.max_requeues = Integer(max)
        end

        help = <<~EOS
          Defines how many requeues can happen overall, based on the test suite size. e.g 0.05 for 5%.
          Defaults to 0.
        EOS
        parser.separator ""
        parser.on('--requeue-tolerance RATIO', *help) do |ratio|
          queue_config.requeue_tolerance = Float(ratio)
        end

        help = <<~EOS
          Defines after how many consecutive failures the worker will be considered unhealthy and terminate itself.
          Defaults to disabled.
        EOS
        parser.separator ""
        parser.on('--max-consecutive-failures MAX', *help) do |max|
          queue_config.max_consecutive_failures = Integer(max)
        end

        parser
      end

      def queue_config
        ::RSpec::Queue.config
      end
    end

    RSpec::Core::Parser.prepend(ParserExtension)

    module ExampleExtension
      protected

      def mark_as_requeued!(reporter)
        @metadata = @metadata.dup # Avoid mutating the @metadata hash of the original Example instance
        @metadata[:execution_result] = execution_result.dup


        failure_notification = RSpec::Core::Notifications::FailedExampleNotification.new(self)
        execution_result.exception = @exception
        execution_result.status = :failed

        presenter = RSpec::Core::Formatters::ExceptionPresenter::Factory.new(self).build
        error_message = presenter.fully_formatted_lines(nil, ::RSpec::Core::Formatters::ConsoleCodes)
        error_message.delete_at(1) # remove the example description

        @exception = nil
        execution_result.exception = nil
        execution_result.status = :pending
        execution_result.pending_message = [
          "The example failed, but another attempt will be done to rule out flakiness",
          *error_message.map { |l| l.empty? ? l : "   " + l },
        ].join("\n")

        # Ensure the example is recorded as ran, so it's visible to formatters
        reporter.example_started(self)
        finish(reporter, acknowledge: false)
      end

      private

      def start(*)
        reset! # In case that example was already ran but got requeued
        super
      end

      def finish(reporter, acknowledge: true)
        if acknowledge && reporter.respond_to?(:requeue)
          if @exception
            reporter.report_failure!
          else
            reporter.report_success!
          end

          if @exception && reporter.requeue
            reporter.cancel_run!
            dup.mark_as_requeued!(reporter)
            return true
          elsif reporter.acknowledge || !@exception
            # If the test was already acknowledged by another worker (we timed out)
            # Then we only record it if it is successful.
            super(reporter)
          else
            reporter.cancel_run!
            return
          end
        else
          super(reporter)
        end
      end

      def reset!
        @exception = nil
        @metadata[:execution_result] = RSpec::Core::Example::ExecutionResult.new
      end
    end

    RSpec::Core::Example.prepend(ExampleExtension)

    class SingleExample
      attr_reader :example_group, :example

      def initialize(example_group, example)
        @example_group = example_group
        @example = example
      end

      def id
        example.id
      end

      def <=>(other)
        id <=> other.id
      end

      def run(reporter)
        instance = example_group.new(example.inspect_output)
        example_group.set_ivars(instance, example_group.before_context_ivars)
        result = example.run(instance, reporter)
        result.nil? ? true : result
      end
    end

    class ReportRunner
      include RunnerHelpers
      include CI::Queue::OutputHelpers

      def call(options, stdout, stderr)
        setup(options, stdout, stderr)

        queue = CI::Queue.from_uri(queue_url, RSpec::Queue.config)

        supervisor = begin
          queue.supervisor
        rescue NotImplementedError => error
          abort! error.message
        end

        step("Waiting for workers to complete")

        unless supervisor.wait_for_workers
          unless supervisor.queue_initialized?
            abort! "No master was elected. Did all workers crash?"
          end

          unless supervisor.exhausted?
            abort! "#{supervisor.size} tests weren't run."
          end
        end

        # TODO: better reporting
        errors = supervisor.build.error_reports.sort_by(&:first).map(&:last)
        if errors.empty?
          step(green('No errors found'))
          0
        else
          message = errors.size == 1 ? "1 error found" : "#{errors.size} errors found"
          step(red(message), collapsed: false)
          puts errors
          1
        end
      end

      private

      attr_reader :configuration

      def setup(options, out, err)
        @options       = options
        @configuration = RSpec.configuration
        @world         = RSpec.world
        @configuration.error_stream = err
        @configuration.output_stream = out if @configuration.output_stream == $stdout
        @options.options.delete(:requires) # Prevent loading of spec_helper so the app doesn't need to boot
        @options.configure(@configuration)

        invalid_usage!('Missing --queue parameter') unless queue_url
        invalid_usage!('Missing --build parameter') unless RSpec::Queue.config.build_id
      end
    end

    class QueueReporter < SimpleDelegator
      def initialize(reporter, queue, example)
        @queue = queue
        @example = example
        super(reporter)
      end

      def report_success!
        @queue.report_success!
      end

      def report_failure!
        @queue.report_failure!
      end

      def requeue
        @queue.requeue(@example)
      end

      def cancel_run!
        # Remove the requeued example from the list of examples ran
        # Otherwise some formatters might break because the example state is reset
        examples.pop
        nil
      end

      def acknowledge
        @queue.acknowledge(@example)
      end
    end

    class Runner < ::RSpec::Core::Runner
      include CI::Queue::OutputHelpers
      include RunnerHelpers

      def setup(err, out)
        super
        invalid_usage!('Missing --queue parameter') unless queue_url
        invalid_usage!('Missing --build parameter') unless RSpec::Queue.config.build_id
        invalid_usage!('Missing --worker parameter') unless RSpec::Queue.config.worker_id
        RSpec.configuration.backtrace_formatter.filter_gem('ci-queue')
      end

      def run_specs(example_groups)
        examples = example_groups.flat_map(&:descendants).flat_map do |example_group|
          example_group.filtered_examples.map do |example|
            SingleExample.new(example_group, example)
          end
        end

        queue = CI::Queue.from_uri(queue_url, RSpec::Queue.config)

        if queue.retrying?
          retry_queue = queue.retry_queue
          if retry_queue.exhausted?
            puts "Found 0 tests to retry, processing the main queue."
          else
            puts "Retrying #{retry_queue.size} failed tests."
            queue = retry_queue
          end
        end

        BuildStatusRecorder.build = queue.build
        queue.populate(examples, random: ordering_seed, &:id)
        examples_count = examples.size # TODO: figure out which stub value would be best
        success = true
        @configuration.reporter.report(examples_count) do |reporter|
          @configuration.add_formatter(BuildStatusRecorder)
          FileUtils.mkdir_p('log')
          @configuration.add_formatter(OrderRecorder, open('log/test_order.log', 'w+'))

          @configuration.with_suite_hooks do
            break if @world.wants_to_quit
            queue.poll do |example|
              success &= example.run(QueueReporter.new(reporter, queue, example))
              break if @world.wants_to_quit
            end
          end
        end

        return 0 if @world.non_example_failure
        success ? 0 : @configuration.failure_exit_code
      end

      private

      def ordering_seed
        if RSpec::Queue.config.seed
          Random.new(Digest::MD5.hexdigest(RSpec::Queue.config.seed).to_i(16))
        else
          Random.new
        end
      end
    end
  end
end
