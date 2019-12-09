# frozen_string_literal: true

module CI
  module Queue
    class Static
      include Common
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

      def build
        @build ||= BuildRecord.new(self)
      end

      def supervisor
        raise NotImplementedError, "This type of queue can't be supervised"
      end

      def retry_queue
        self
      end

      def populate(tests, random: nil)
        @index = tests.map { |t| [t.id, t] }.to_h
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
        while !config.circuit_breakers.any?(&:open?) && test = @queue.shift
          yield index.fetch(test)
        end
      end

      def exhausted?
        @queue.empty?
      end

      def acknowledge(test)
        @progress += 1
        true
      end

      def requeue(test)
        test_key = test.id
        return false unless should_requeue?(test_key)
        requeues[test_key] += 1
        @queue.unshift(test_key)
        true
      end

      private

      attr_reader :index

      def should_requeue?(key)
        requeues[key] < config.max_requeues && requeues.values.inject(0, :+) < config.global_max_requeues(total)
      end

      def requeues
        @requeues ||= Hash.new(0)
      end
    end
  end
end
