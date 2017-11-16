module Minitest
  module Queue
    class Runner
      Error = Class.new(StandardError)
      MissingParameter = Class.new(Error)

      def self.invoke(argv)
        new(argv).run!
      end

      def initialize(argv)
        @argv, @options = parse(argv)
      end

      def run!
        Minitest.queue = queue

        if paths = @options[:load_paths]
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
          queue = CI::Queue.from_uri(queue_url)
          queue = queue.retry_queue if @options[:retry]
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
        end.parse!(argv)
        return argv, options
      end

      def queue_url
        @options[:url] || ENV['CI_QUEUE_URL'] || abort!('TODO: explain queue url is required')
      end

      def abort!(message)
        puts message
        exit! 1 # exit! is required to avoid minitest at_exit callback
      end
    end
  end
end
