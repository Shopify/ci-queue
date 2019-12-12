# frozen_string_literal: true
require 'optparse'
require 'json'
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
        STDERR.puts "Warning: the retry subcommand is deprecated."
        run_command # aliased for backward compatibility purpose
      end

      def run_command
        if queue.retrying?
          reset_counters
          retry_queue = queue.retry_queue
          if retry_queue.exhausted?
            puts "The retry queue does not contain any failure, we'll process the main queue instead."
          else
            puts "Retrying failed tests."
            self.queue = retry_queue
          end
        end

        set_load_path
        Minitest.queue = queue
        reporters = [
          LocalRequeueReporter.new,
          BuildStatusRecorder.new(build: queue.build),
          JUnitReporter.new,
          TestDataReporter.new(namespace: queue_config&.namespace),
          OrderReporter.new(path: 'log/test_order.log'),
        ]
        if queue_config.statsd_endpoint
          reporters << Minitest::Reporters::StatsdReporter.new(statsd_endpoint: queue_config.statsd_endpoint)
        end
        Minitest.queue_reporters = reporters

        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }

        if queue.rescue_connection_errors { queue.exhausted? }
          puts green('All tests were ran already')
        else
          load_tests
          populate_queue
        end
        # Let minitest's at_exit hook trigger
      end

      def grind_command
        invalid_usage!('No list to grind provided') if grind_list.nil?
        invalid_usage!('No grind count provided') if grind_count.nil?

        set_load_path

        queue_config.build_id = queue_config.build_id + '-grind'
        queue_config.grind_count = grind_count

        reporter_queue = CI::Queue::Redis::Grind.new(queue_url, queue_config)
        test_time_record = CI::Queue::Redis::TestTimeRecord.new(queue_url, queue_config)

        Minitest.queue = queue
        reporters = [
          GrindRecorder.new(build: reporter_queue.build),
          TestDataReporter.new(namespace: queue_config&.namespace),
          TestTimeRecorder.new(build: test_time_record)
        ]
        if queue_config.statsd_endpoint
          reporters << Minitest::Reporters::StatsdReporter.new(statsd_endpoint: queue_config.statsd_endpoint)
        end
        Minitest.queue_reporters = reporters

        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }

        load_tests

        @queue = CI::Queue::Grind.new(grind_list, queue_config)
        Minitest.queue = queue
        populate_queue

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

        unless supervisor.wait_for_workers { display_warnings(supervisor.build) }
          unless supervisor.queue_initialized?
            abort! "No master was elected. Did all workers crash?"
          end

          unless supervisor.exhausted?
            abort! "#{supervisor.size} tests weren't run."
          end
        end

        reporter = BuildStatusReporter.new(build: supervisor.build)

        if queue_config.failure_file
          failures = reporter.error_reports.map(&:to_h).to_json
          File.write(queue_config.failure_file, failures)
        end

        reporter.report
        exit! reporter.success? ? 0 : 1
      end

      def report_grind_command
        queue_config.build_id = queue_config.build_id + '-grind'
        @queue = CI::Queue::Redis::Grind.new(queue_url, queue_config)

        supervisor = begin
          queue.supervisor
        rescue NotImplementedError => error
          abort! error.message
        end

        grind_reporter = GrindReporter.new(build: supervisor.build)
        grind_reporter.report

        test_time_record = CI::Queue::Redis::TestTimeRecord.new(queue_url, queue_config)
        test_time_reporter = Minitest::Queue::TestTimeReporter.new(
          build: test_time_record,
          limit: queue_config.max_test_duration,
          percentile: queue_config.max_test_duration_percentile,
        )
        test_time_reporter.report

        exit! grind_reporter.success? && test_time_reporter.success? ? 0 : 1
      end

      private

      attr_reader :queue_config, :options, :command, :argv
      attr_accessor :queue, :queue_url, :grind_list, :grind_count, :load_paths

      def display_warnings(build)
        build.pop_warnings.each do |type, attributes|
          case type
          when CI::Queue::Warnings::RESERVED_LOST_TEST
            puts reopen_previous_step
            puts yellow(
              "[WARNING] #{attributes[:test]} was picked up by another worker because it didn't complete in the allocated #{attributes[:timeout]} seconds.\n" \
              "You may want to either optimize this test or bump ci-queue timeout.\n" \
              "It's also possible that the worker that was processing it was terminated without being able to report back.\n"
            )
          end
        end
      end

      def run_tests_in_fork(queue)
        child_pid = fork do
          Minitest.queue = queue
          Minitest::Reporters.use!([Minitest::Reporters::BisectReporter.new])
          exit # let minitest excute its at_exit
        end

        _, status = Process.wait2(child_pid)
        return status.success?
      end

      def reset_counters
        queue.build.reset_stats(BuildStatusRecorder::COUNTERS)
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


          help = <<~EOS
            URL of the queue, e.g. redis://example.com.
            Defaults to $CI_QUEUE_URL if set.
          EOS
          opts.separator ""
          opts.on('--queue URL', help) do |url|
            self.queue_url = url
          end

          help = <<~EOS
            Path to the file that includes the list of tests to grind.
          EOS
          opts.separator ""
          opts.on('--grind-list PATH', help) do |url|
            self.grind_list = url
          end

          help = <<~EOS
            Count defines how often each test in the grind list is going to be run.
          EOS
          opts.separator ""
          opts.on('--grind-count COUNT', help) do |count|
            self.grind_count = count.to_i
          end

          help = <<~EOS
            Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier.
            If the build is tried again, or another revision is built, this value must be different.
            It's automatically inferred on Buildkite, CircleCI, Heroku CI, and Travis.
          EOS
          opts.separator ""
          opts.on('--build BUILD_ID', help) do |build_id|
            queue_config.build_id = build_id
          end

          help = <<~EOS
            Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites.
              Example: --namespace integration
          EOS
          opts.separator ""
          opts.on('--namespace NAMESPACE', help) do |namespace|
            queue_config.namespace = namespace
          end

          opts.separator ""
          opts.separator "COMMANDS"
          opts.separator ""
          opts.separator "    run [TEST_FILES...]: Participate in leader election, and then work off the test queue."

          help = <<~EOS
            Specify a timeout after which if a test haven't completed, it will be picked up by another worker.
            It is very important to set this vlaue higher than the slowest test in the suite, otherwise performance will be impacted.
            Defaults to 30 seconds.
          EOS
          opts.separator ""
          opts.on('--timeout TIMEOUT', Float, help) do |timeout|
            queue_config.timeout = timeout
          end

          help = <<~EOS
            Specify $LOAD_PATH directory, similar to Ruby's -I
          EOS
          opts.separator ""
          opts.on('-IPATHS', help) do |paths|
            self.load_paths = paths
          end

          help = <<~EOS
            Sepcify a seed used to shuffle the test suite.
            On Buildkite, CircleCI, Heroku CI, and Travis, the commit revision will be used by default.
          EOS
          opts.separator ""
          opts.on('--seed SEED', help) do |seed|
            queue_config.seed = seed
          end

          help = <<~EOS
            A unique identifier for this worker, It must be consistent to allow retries.
            If not specified, retries won't be available.
            It's automatically inferred on Buildkite, Heroku CI, and CircleCI.
          EOS
          opts.separator ""
          opts.on('--worker WORKER_ID', help) do |worker_id|
            queue_config.worker_id = worker_id
          end

          help = <<~EOS
            Defines how many time a single test can be requeued.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--max-requeues MAX', Integer, help) do |max|
            queue_config.max_requeues = max
          end

          help = <<~EOS
            Defines how long ci-queue should maximally run in seconds
            Defaults to none.
          EOS
          opts.separator ""
          opts.on('--max-duration SECONDS', Integer, help) do |max|
            queue_config.max_duration = max
          end

          help = <<~EOS
            Defines how many requeues can happen overall, based on the test suite size. e.g 0.05 for 5%.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--requeue-tolerance RATIO', Float, help) do |ratio|
            queue_config.requeue_tolerance = ratio
          end

          help = <<~EOS
            Defines a file where the test failures are written to in the json format.
            Defaults to disabled.
          EOS
          opts.separator ""
          opts.on('--failure-file FILE', help) do |file|
            queue_config.failure_file = file
          end

          help = <<~EOS
            Defines after how many consecutive failures the worker will be considered unhealthy and terminate itself.
            Defaults to disabled.
          EOS
          opts.separator ""
          opts.on('--max-consecutive-failures MAX', Integer, help) do |max|
            queue_config.max_consecutive_failures = max
          end

          help = <<~EOS
            Set the time limit of the execution time from grinds on a given test.
            For example, when max-test-duration is set to 10 and
            max-test-duration-percentile is set to 0.5, the test's median execution time during a grind must be
            lower than 10 milliseconds.
            The unit is milliseconds and decimal is allowed.
            Defaults to disabled.
          EOS
          opts.on('--max-test-duration LIMIT_IN_MILLISECONDS', Float, help) do |limit|
            queue_config.max_test_duration = limit
          end

          help = <<~EOS
            The percentile for max-test-duration. For example, when max-test-duration is set to 10 and
            max-test-duration-percentile is set to 0.5, the test's median execution time during a grind must be
            lower than 10 milliseconds.
            The percentile must be within the range 0 < percentile <= 1.
            Defaults to 0.5 (50th percentile).
          EOS
          opts.on('--max-test-duration-percentile LIMIT_IN_MILLISECONDS', Float, help) do |percentile|
            queue_config.max_test_duration_percentile = percentile
            if queue_config.max_test_duration_percentile <= 0 || queue_config.max_test_duration_percentile > 1
              raise OptionParser::ParseError.new("must be within range (0, 1]")
            end
          end

          opts.separator ""
          opts.separator "    retry: Replays a previous run in the same order."

          opts.separator ""
          opts.separator "    report: Wait for all workers to complete and summarize the test failures."

          opts.separator ""
          opts.separator "    bisect: bisect a test suite to find global state leaks."
          help = <<~EOS
            The identifier of the failing test.
          EOS
          opts.separator ""
          opts.on('--failing-test TEST_IDENTIFIER') do |identifier|
            queue_config.failing_test = identifier
          end
        end
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
