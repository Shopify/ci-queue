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
      attr_accessor :entry_resolver

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

      # Support lazy loading mode: accept an enumerator of entries and
      # store them in queue order (no shuffling). This preserves the
      # exact order from the input file for local reproduction.
      def stream_populate(tests, random: nil, batch_size: nil)
        @queue = []
        tests.each { |entry| @queue << entry }
        @total = @queue.size
        self
      end

      def with_heartbeat(id, lease: nil)
        yield
      end

      def lease_for(entry)
        nil
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
        !!defined?(@index) || @queue.any?
      end

      def to_a
        if defined?(@index) && @index
          @queue.map { |i| index.fetch(i) }
        else
          @queue.dup
        end
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
          if entry_resolver
            resolved = entry_resolver.call(reserved_test)
            # Track the original queue entry so requeue can push it back
            # with its full payload (file path, load-error data, etc.).
            reserved_entries[resolved.id] = reserved_test if resolved.respond_to?(:id)
            yield resolved
          elsif defined?(@index) && @index
            # Queue entries may be JSON-formatted (with test_id + file_path) while
            # the index is keyed by bare test_id from populate. Try the raw entry
            # first, then fall back to extracting the test_id.
            test_id = begin
              CI::Queue::QueueEntry.test_id(reserved_test)
            rescue JSON::ParserError
              reserved_test
            end
            yield index.fetch(test_id)
          else
            yield reserved_test
          end
        end
        reserved_tests.clear
        reserved_entries.clear
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

      def requeue(entry)
        test_id = CI::Queue::QueueEntry.test_id(entry)
        return false unless should_requeue?(test_id)

        requeues[test_id] += 1
        # Push back the original queue entry (with file path / load-error payload)
        # so entry_resolver can fully resolve it on the next poll iteration.
        original_entry = reserved_entries.delete(test_id) || test_id
        @queue.unshift(original_entry)
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

      def reserved_entries
        @reserved_entries ||= {}
      end

      def reserved_tests
        @reserved_tests ||= Concurrent::Set.new
      end
    end
  end
end
