require 'optparse'
require 'minitest/queue'
require 'ci/queue'
require 'digest/md5'

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
        @command, @argv, @options = parse(argv)
        @queue = CI::Queue.from_uri(queue_url, queue_config)
      end

      def run!
        method = "#{command}_command"
        if respond_to?(method)
          public_send(method)
        else
          abort!("Unknown command: #{command}")
        end
      end

      def retry_command
        self.queue = queue.retry_queue
        run_command
      end

      def run_command
        set_load_path
        Minitest.queue = queue
        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }
        load_tests
        populate_queue
        # Let minitest's at_exit hook trigger
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

        success = supervisor.minitest_reporters.all?(&:success?)
        supervisor.minitest_reporters.each do |reporter|
          reporter.report
        end

        STDOUT.flush
        exit! success ? 0 : 1
      end

      private

      attr_reader :queue_config, :options, :command, :argv
      attr_accessor :queue

      def queue
        @queue ||= begin
          queue =
          queue = queue.retry_queue if options[:retry]
          queue
        end
      end

      def populate_queue
        Minitest.queue.populate(shuffle(Minitest.loaded_tests), &:to_s) # TODO: stop serializing
      end

      def set_load_path
        if paths = options[:load_paths]
          paths.split(':').reverse.each do |path|
            $LOAD_PATH.unshift(File.expand_path(path))
          end
        end
      end

      def load_tests
        argv.each do |f|
          require File.expand_path(f)
        end
      end

      def parse(argv, options = {})
        OptionParser.new do |opts|
          opts.banner = "Usage: minitest-queue [options] ACTION TEST_FILE..."

          opts.on('-I PATHS') do |paths|
            options[:load_paths] = paths
          end

          opts.on('--url URL') do |url|
            options[:url] = url
          end

          opts.on('--seed SEED') do |seed|
            queue_config.seed = seed
          end

          opts.on('--timeout TIMEOUT') do |timeout|
            queue_config.timeout = Float(timeout)
          end

          opts.on('--namespace NAMESPACE') do |namespace|
            queue_config.namespace = namespace
          end

          opts.on('--build BUILD_ID') do |build_id|
            queue_config.build_id = build_id
          end

          opts.on('--worker WORKER_ID') do |worker_id|
            queue_config.worker_id = worker_id
          end

          opts.on('--max-requeues MAX') do |max|
            queue_config.max_requeues = Integer(max)
          end

          opts.on('--requeue-tolerance RATIO') do |ratio|
            queue_config.requeue_tolerance = Float(ratio)
          end
        end.parse!(argv)
        command = argv.shift
        return command, argv, options
      end

      def shuffle(tests)
        random = Random.new(Digest::MD5.hexdigest(queue_config.seed).to_i(16))
        tests.shuffle(random: random)
      end

      def queue_url
        options[:url] || ENV['CI_QUEUE_URL'] || abort!('TODO: explain queue url is required')
      end

      def abort!(message)
        puts red(message)
        reopen_previous_step
        exit! 1 # exit! is required to avoid minitest at_exit callback
      end
    end
  end
end
