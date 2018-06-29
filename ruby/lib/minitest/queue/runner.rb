require 'optparse'
require 'minitest/queue'
require 'ci/queue'
require 'digest/md5'
require 'minitest/reporters/bisect_reporter'
require 'minitest/reporters/statsd_reporter'

module Minitest
  module Queue
    class Runner
      include ::CI::Queue::OutputHelpers

      Error = Class.new(StandardError)
      MissingParameter = Class.new(Error)

      def self.invoke(argv)
        new(argv).run!
      end

      def initialize(argv)
        @queue_config = CI::Queue::Configuration.from_env(ENV)
        @command, @argv = parse(argv)
      end

      def run!
        invalid_usage!("No command given") if command.nil?
        invalid_usage!('Missing queue URL') unless queue_url

        @queue = CI::Queue.from_uri(queue_url, queue_config)

        method = "#{command}_command"
        if respond_to?(method)
          public_send(method)
        else
          invalid_usage!("Unknown command: #{command}")
        end
      end

      def retry_command
        self.queue = queue.retry_queue
        run_command
      end

      def run_command
        set_load_path
        Minitest.queue = queue
        reporters = [
          LocalRequeueReporter.new,
          BuildStatusRecorder.new(build: queue.build),
          JUnitReporter.new,
          OrderReporter.new(path: 'log/test_order.log'),
        ]
        if queue_config.statsd_endpoint
          reporters << Minitest::Reporters::StatsdReporter.new(statsd_endpoint: queue_config.statsd_endpoint)
        end
        Minitest.queue_reporters = reporters

        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }

        unless queue.rescue_connection_errors { queue.exhausted? }
          load_tests
          populate_queue
        end
        # Let minitest's at_exit hook trigger
      end

      def bisect_command
        invalid_usage! "Missing the FAILING_TEST argument." unless queue_config.failing_test

        @queue = CI::Queue::Bisect.new(queue_url, queue_config)
        Minitest.queue = queue
        set_load_path
        load_tests
        populate_queue

        step("Testing the failing test in isolation")
        unless run_tests_in_fork(queue.failing_test)
          puts reopen_previous_step
          puts red("The test fail when ran alone, no need to bisect.")
          exit! 0
        end

        run_index = 0
        while queue.suspects_left > 1
          run_index += 1
          step("Run ##{run_index}, #{queue.suspects_left} suspects left")
          if run_tests_in_fork(queue.candidates)
            queue.succeeded!
          else
            queue.failed!
          end
          puts
        end

        failing_order = queue.candidates
        step("Final validation")
        status = if run_tests_in_fork(failing_order)
          step(yellow("The bisection was inconclusive, there might not be any leaky test here."))
          exit! 1
        else
          step(green('The following command should reproduce the leak on your machine:'), collapsed: false)
          command = %w(bundle exec minitest-queue --queue - run)
          command << "-I#{load_paths}" if load_paths
          command += argv

          puts
          puts "cat <<EOF |\n#{failing_order.to_a.map(&:id).join("\n")}\nEOF\n#{command.join(' ')}"
          puts
          exit! 0
        end
      end

      def report_command
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

        reporter = BuildStatusReporter.new(build: supervisor.build)
        reporter.report
        exit! reporter.success? ? 0 : 1
      end

      private

      attr_reader :queue_config, :options, :command, :argv
      attr_accessor :queue, :queue_url, :load_paths

      def run_tests_in_fork(queue)
        child_pid = fork do
          Minitest.queue = queue
          Minitest::Reporters.use!([Minitest::Reporters::BisectReporter.new])
          exit # let minitest excute its at_exit
        end

        _, status = Process.wait2(child_pid)
        return status.success?
      end

      def populate_queue
        Minitest.queue.populate(Minitest.loaded_tests, random: ordering_seed, &:id)
      end

      def set_load_path
        if paths = load_paths
          paths.split(':').reverse.each do |path|
            $LOAD_PATH.unshift(File.expand_path(path))
          end
        end
      end

      def load_tests
        argv.sort.each do |f|
          require File.expand_path(f)
        end
      end

      def parse(argv)
        parser.parse!(argv)
        command = argv.shift
        return command, argv
      end

      def parser
        @parser ||= OptionParser.new do |opts|
          opts.banner = "Usage: minitest-queue [options] COMMAND [ARGS]"

          opts.separator ""
          opts.separator "Example: minitest-queue -Itest --queue redis://example.com run test/**/*_test.rb"

          opts.separator ""
          opts.separator "GLOBAL OPTIONS"


          help = split_heredoc(<<-EOS)
            URL of the queue, e.g. redis://example.com.
            Defaults to $CI_QUEUE_URL if set.
          EOS
          opts.separator ""
          opts.on('--queue URL', *help) do |url|
            self.queue_url = url
          end

          help = split_heredoc(<<-EOS)
            Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier.
            If the build is tried again, or another revision is built, this value must be different.
            It's automatically inferred on Buildkite, CircleCI, Heroku CI, and Travis.
          EOS
          opts.separator ""
          opts.on('--build BUILD_ID', *help) do |build_id|
            queue_config.build_id = build_id
          end

          help = split_heredoc(<<-EOS)
            Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites.
              Example: --namespace integration
          EOS
          opts.separator ""
          opts.on('--namespace NAMESPACE', *help) do |namespace|
            queue_config.namespace = namespace
          end

          opts.separator ""
          opts.separator "COMMANDS"
          opts.separator ""
          opts.separator "    run [TEST_FILES...]: Participate in leader election, and then work off the test queue."

          help = split_heredoc(<<-EOS)
            Specify a timeout after which if a test haven't completed, it will be picked up by another worker.
            It is very important to set this vlaue higher than the slowest test in the suite, otherwise performance will be impacted.
            Defaults to 30 seconds.
          EOS
          opts.separator ""
          opts.on('--timeout TIMEOUT', *help) do |timeout|
            queue_config.timeout = Float(timeout)
          end

          help = split_heredoc(<<-EOS)
            Specify $LOAD_PATH directory, similar to Ruby's -I
          EOS
          opts.separator ""
          opts.on('-IPATHS', *help) do |paths|
            self.load_paths = paths
          end

          help = split_heredoc(<<-EOS)
            Sepcify a seed used to shuffle the test suite.
            On Buildkite, CircleCI, Heroku CI, and Travis, the commit revision will be used by default.
          EOS
          opts.separator ""
          opts.on('--seed SEED', *help) do |seed|
            queue_config.seed = seed
          end

          help = split_heredoc(<<-EOS)
            A unique identifier for this worker, It must be consistent to allow retries.
            If not specified, retries won't be available.
            It's automatically inferred on Buildkite, Heroku CI, and CircleCI.
          EOS
          opts.separator ""
          opts.on('--worker WORKER_ID', *help) do |worker_id|
            queue_config.worker_id = worker_id
          end

          help = split_heredoc(<<-EOS)
            Defines how many time a single test can be requeued.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--max-requeues MAX', *help) do |max|
            queue_config.max_requeues = Integer(max)
          end

          help = split_heredoc(<<-EOS)
            Defines how many requeues can happen overall, based on the test suite size. e.g 0.05 for 5%.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--requeue-tolerance RATIO', *help) do |ratio|
            queue_config.requeue_tolerance = Float(ratio)
          end

          help = split_heredoc(<<-EOS)
            Defines after how many consecutive failures the worker will be considered unhealthy and terminate itself.
            Defaults to disabled.
          EOS
          opts.separator ""
          opts.on('--max-consecutive-failures MAX', *help) do |max|
            queue_config.max_consecutive_failures = Integer(max)
          end

          opts.separator ""
          opts.separator "    retry: Replays a previous run in the same order."

          opts.separator ""
          opts.separator "    report: Wait for all workers to complete and summarize the test failures."

          opts.separator ""
          opts.separator "    bisect: bisect a test suite to find global state leaks."
          help = split_heredoc(<<-EOS)
            The identifier of the failing test.
          EOS
          opts.separator ""
          opts.on('--failing-test TEST_IDENTIFIER') do |identifier|
            queue_config.failing_test = identifier
          end
        end
      end

      def split_heredoc(string)
        string.lines.map(&:strip)
      end

      def ordering_seed
        if queue_config.seed
          Random.new(Digest::MD5.hexdigest(queue_config.seed).to_i(16))
        else
          Random.new
        end
      end

      def queue_url
        @queue_url || ENV['CI_QUEUE_URL']
      end

      def invalid_usage!(message)
        reopen_previous_step
        puts red(message)
        puts parser
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
