require 'rspec/core'
require 'ci/queue'

module RSpec
  module Queue
    class << self
      def config
        @config ||= CI::Queue::Configuration.from_env(ENV)
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

        help = split_heredoc(<<-EOS)
          URL of the queue, e.g. redis://example.com.
          Defaults to $CI_QUEUE_URL if set.
        EOS
        parser.separator ""
        parser.on('--queue URL', *help) do |url|
          options[:queue_url] = url
        end

        help = split_heredoc(<<-EOS)
          Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier.
          If the build is tried again, or another revision is built, this value must be different.
          It's automatically inferred on Buildkite, CircleCI and Travis.
        EOS
        parser.separator ""
        parser.on('--build BUILD_ID', *help) do |build_id|
          queue_config.build_id = build_id
        end

        help = split_heredoc(<<-EOS)
          Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites.
            Example: --namespace integration
        EOS
        parser.separator ""
        parser.on('--namespace NAMESPACE', *help) do |namespace|
          queue_config.namespace = namespace
        end

        help = split_heredoc(<<-EOS)
          Specify a timeout after which if a test haven't completed, it will be picked up by another worker.
          It is very important to set this vlaue higher than the slowest test in the suite, otherwise performance will be impacted.
          Defaults to 30 seconds.
        EOS
        parser.separator ""
        parser.on('--timeout TIMEOUT', *help) do |timeout|
          queue_config.timeout = Float(timeout)
        end

        help = split_heredoc(<<-EOS)
          A unique identifier for this worker, It must be consistent to allow retries.
          If not specified, retries won't be available.
          It's automatically inferred on Buildkite and CircleCI.
        EOS
        parser.separator ""
        parser.on('--worker WORKER_ID', *help) do |worker_id|
          queue_config.worker_id = worker_id
        end

        help = split_heredoc(<<-EOS)
          Defines how many time a single test can be requeued.
          Defaults to 0.
        EOS
        parser.separator ""
        parser.on('--max-requeues MAX', *help) do |max|
          queue_config.max_requeues = Integer(max)
        end

        help = split_heredoc(<<-EOS)
          Defines how many requeues can happen overall, based on the test suite size. e.g 0.05 for 5%.
          Defaults to 0.
        EOS
        parser.separator ""
        parser.on('--requeue-tolerance RATIO', *help) do |ratio|
          queue_config.requeue_tolerance = Float(ratio)
        end

        parser
      end

      def split_heredoc(string)
        string.lines.map(&:strip)
      end

      def queue_config
        ::RSpec::Queue.config
      end
    end

    RSpec::Core::Parser.prepend(ParserExtension)

    class SingleExample
      attr_reader :example_group, :example

      def initialize(example_group, example)
        @example_group = example_group
        @example = example
      end

      def id
        example.id
      end

      def run(reporter)
        return if RSpec.world.wants_to_quit
        instance = example_group.new(example.inspect_output)
        example_group.set_ivars(instance, example_group.before_context_ivars)
        succeeded = example.run(instance, reporter)
        if !succeeded && reporter.fail_fast_limit_met?
          RSpec.world.wants_to_quit = true
        end
        succeeded
      end
    end

    class Runner < ::RSpec::Core::Runner
      include CI::Queue::OutputHelpers

      def setup(err, out)
        super
        invalid_usage!('Missing --queue parameter') unless queue_url
        invalid_usage!('Missing --build parameter') unless RSpec::Queue.config.build_id
        invalid_usage!('Missing --worker parameter') unless RSpec::Queue.config.worker_id
      end

      def run_specs(example_groups)
        examples = example_groups.flat_map(&:descendants).flat_map do |example_group|
          example_group.filtered_examples.map do |example|
            SingleExample.new(example_group, example)
          end
        end

        queue = CI::Queue.from_uri(queue_url, RSpec::Queue.config)
        queue.populate(examples, &:id)
        examples_count = examples.size # TODO: figure out which stub value would be best
        success = true
        @configuration.reporter.report(examples_count) do |reporter|
          @configuration.with_suite_hooks do
            queue.poll do |example|
              success &= example.run(reporter)
              queue.acknowledge(example)
            end
          end
        end

        success &= !@world.non_example_failure
        success ? 0 : @configuration.failure_exit_code
      end

      private

      def queue_url
        configuration.queue_url || ENV['CI_QUEUE_URL']
      end

      def invalid_usage!(message)
        reopen_previous_step
        puts red(message)
        puts
        puts 'Please use --help for a listing of valid options'
        exit! 1 # exit! is required to avoid minitest at_exit callback
      end

      def exit!(*)
        STDOUT.flush
        STDERR.flush
        super
      end

      def abort!(message)
        reopen_previous_step
        puts red(message)
        exit! 1 # exit! is required to avoid minitest at_exit callback
      end
    end
  end
end
