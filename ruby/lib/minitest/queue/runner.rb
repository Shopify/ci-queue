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
        @queue_config = CI::Queue::Configuration.new(ENV, argv).config
        @command = argv[0]
        @files = argv[1..-1]
      end

      def run!
        invalid_usage!("No command given") if command.nil?
        invalid_usage!('Missing queue URL') unless queue_config.queue_url

        @queue = CI::Queue.from_uri(queue_config.queue_url, queue_config)

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
        invalid_usage!('No list to grind provided') if queue_config.grind_list.nil?
        invalid_usage!('No grind count provided') if queue_config.grind_count.nil?

        set_load_path

        queue_config.build_id = queue_config.build_id + '-grind'

        reporter_queue = CI::Queue::Redis::Grind.new(queue_config.queue_url, queue_config)

        Minitest.queue = queue
        reporters = [
          GrindRecorder.new(build: reporter_queue.build)
        ]
        if queue_config.statsd_endpoint
          reporters << Minitest::Reporters::StatsdReporter.new(statsd_endpoint: queue_config.statsd_endpoint)
        end
        Minitest.queue_reporters = reporters

        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }

        load_tests

        @queue = CI::Queue::Grind.new(queue_config.grind_list, queue_config)
        Minitest.queue = queue
        populate_queue

        # Let minitest's at_exit hook trigger
      end

      def bisect_command
        invalid_usage! "Missing the FAILING_TEST argument." unless queue_config.failing_test

        @queue = CI::Queue::Bisect.new(queue_config.queue_url, queue_config)
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
          command += files

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
        @queue = CI::Queue::Redis::Grind.new(queue_config.queue_url, queue_config)

        supervisor = begin
          queue.supervisor
        rescue NotImplementedError => error
          abort! error.message
        end

        reporter = GrindReporter.new(build: supervisor.build)
        reporter.report
        exit! reporter.success? ? 0 : 1
      end

      private

      attr_reader :queue_config, :options, :command, :files
      attr_accessor :queue, :load_paths

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
        files.sort.each do |f|
          require File.expand_path(f)
        end
      end

      def ordering_seed
        if queue_config.seed
          Random.new(Digest::MD5.hexdigest(queue_config.seed).to_i(16))
        else
          Random.new
        end
      end

      def invalid_usage!(message)
        reopen_previous_step
        puts red(message)
        # puts CI::Queue::ParseArgv.help
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
