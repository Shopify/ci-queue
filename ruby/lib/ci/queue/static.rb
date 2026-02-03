# frozen_string_literal: true

require 'concurrent/set'

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

      TEN_MINUTES = 60 * 10

      attr_reader :progress, :total

      def initialize(tests, config)
        @queue = tests
        @config = config
        @progress = 0
        @total = tests.size
        @shutdown = false
      end

      def shutdown!
        @shutdown = true
      end

      def distributed?
        false
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

      def populate_lazy(test_files:, random:, config:)
        raise NotImplementedError, "Lazy loading is not supported for static queues. " \
                                   "Use a Redis queue (redis://) for lazy loading support."
      end

      def with_heartbeat(id)
        yield
      end

      def ensure_heartbeat_thread_alive!; end

      def boot_heartbeat_process!; end

      def stop_heartbeat!; end

      def report_worker_error(error); end

      def queue_initialized?
        true
      end

      def created_at=(timestamp)
        @created_at ||= timestamp
      end

      def expired?
        (@created_at.to_f + TEN_MINUTES) < CI::Queue.time_now.to_f
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

      def remaining
        @queue.size
      end

      def running
        reserved_tests.empty? ? 0 : 1
      end

      def poll
        while !@shutdown && config.circuit_breakers.none?(&:open?) && !max_test_failed? && reserved_test = @queue.shift
          reserved_tests << reserved_test
          yield index.fetch(reserved_test)
        end
        reserved_tests.clear
      end

      def exhausted?
        @queue.empty?
      end

      def acknowledge(...)
        @progress += 1
        true
      end

      def increment_test_failed(...)
        @test_failed = test_failed + 1
      end

      def test_failed
        @test_failed ||= 0
      end

      def max_test_failed?
        return false if config.max_test_failed.nil?

        test_failed >= config.max_test_failed
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

      def reserved_tests
        @reserved_tests ||= Concurrent::Set.new
      end
    end
  end
end
