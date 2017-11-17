require 'optparse'
require 'minitest/queue'
require 'ci/queue'

module Minitest
  module Queue
    class Runner
      Error = Class.new(StandardError)
      MissingParameter = Class.new(Error)

      def self.invoke(argv)
        new(argv).run!
      end

      attr_reader :queue_config, :options

      def initialize(argv)
        @queue_config = CI::Queue::Configuration.new
        @argv, @options = parse(argv)
      end

      def run!
        Minitest.queue = queue

        if paths = options[:load_paths]
          paths.split(':').reverse.each do |path|
            $LOAD_PATH.unshift(path)
          end
        end

        @argv.each do |f|
          require File.expand_path(f)
        end

        Minitest.queue.populate(Minitest.loaded_tests, &:to_s) # TODO: stop serializing
        trap('TERM') { Minitest.queue.shutdown! }
        trap('INT') { Minitest.queue.shutdown! }
        # Let minitest's at_exit hook trigger
      end

      def queue
        @queue ||= begin
          queue = CI::Queue.from_uri(queue_url, queue_config)
          queue = queue.retry_queue if options[:retry]
          queue
        end
      end

      def parse(argv, options = {})
        OptionParser.new do |opts|
          opts.banner = "Usage: minitest-queue [options] TEST_FILE..."

          opts.on('-I PATHS') do |paths|
            options[:load_paths] = paths
          end

          opts.on('--url URL') do |url|
            options[:url] = url
          end

          opts.on('--retry') do
            options[:retry] = true
          end

          opts.on('--timeout TIMEOUT') do |timeout|
            queue_config.timeout = Float(timeout)
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
        return argv, options
      end

      def queue_url
        options[:url] || ENV['CI_QUEUE_URL'] || abort!('TODO: explain queue url is required')
      end

      def abort!(message)
        puts message
        exit! 1 # exit! is required to avoid minitest at_exit callback
      end
    end
  end
end
