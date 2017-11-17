module CI
  module Queue
    class Static
      class << self
        def from_uri(uri, config)
          tests = uri.opaque.split(':').map { |t| CGI.unescape(t) }
          new(tests, config)
        end
      end

      attr_reader :progress, :total

      def initialize(tests, config)
        @queue = tests
        @config = config
        @progress = 0
        @total = tests.size
      end

      def minitest_reporters
        require 'minitest/reporters/queue_reporter'
        @minitest_reporters ||= [
          Minitest::Reporters::QueueReporter.new,
        ]
      end

      def retry_queue
        self
      end

      def populate(tests, &indexer)
        @index = Index.new(tests, &indexer)
        self
      end

      def populated?
        !!defined?(@index)
      end

      def to_a
        @queue.map { |i| index.fetch(i) }
      end

      def size
        @queue.size
      end

      def poll
        while test = @queue.shift
          yield index.fetch(test)
          @progress += 1
        end
      end

      def exhausted?
        @queue.empty?
      end

      def acknowledge(test)
        true
      end

      def requeue(test)
        key = index.key(test)
        return false unless should_requeue?(key)
        requeues[key] += 1
        @queue.unshift(index.key(test))
        true
      end

      private

      attr_reader :index, :config

      def should_requeue?(key)
        requeues[key] < config.max_requeues && requeues.values.inject(0, :+) < config.global_max_requeues(total)
      end

      def requeues
        @requeues ||= Hash.new(0)
      end
    end
  end
end
