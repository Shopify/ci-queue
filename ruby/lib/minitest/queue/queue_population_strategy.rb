# frozen_string_literal: true

require 'set'
require 'minitest/queue/lazy_entry_resolver'
require 'minitest/queue/lazy_test_discovery'

module Minitest
  module Queue
    class QueuePopulationStrategy
      attr_reader :load_tests_duration, :total_files

      def initialize(queue:, queue_config:, argv:, test_files_file:, ordering_seed:, preresolved_test_list: nil)
        @queue = queue
        @queue_config = queue_config
        @argv = argv
        @test_files_file = test_files_file
        @ordering_seed = ordering_seed
        @preresolved_test_list = preresolved_test_list
      end

      def load_and_populate!
        load_tests
        populate_queue
      end

      private

      attr_reader :queue, :queue_config, :argv, :test_files_file, :ordering_seed, :preresolved_test_list

      def populate_queue
        if preresolved_test_list && queue.respond_to?(:stream_populate)
          configure_lazy_queue
          queue.stream_populate(preresolved_entry_enumerator, random: ordering_seed, batch_size: queue_config.lazy_load_stream_batch_size)
        elsif queue_config.lazy_load && queue.respond_to?(:stream_populate)
          configure_lazy_queue
          queue.stream_populate(lazy_test_enumerator, random: ordering_seed, batch_size: queue_config.lazy_load_stream_batch_size)
        else
          queue.populate(Minitest.loaded_tests, random: ordering_seed)
        end
      end

      def load_tests
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if preresolved_test_list || queue_config.lazy_load
          # In preresolved or lazy-load mode, test files are loaded on-demand by the entry resolver.
          # Load test helpers (e.g., test/test_helper.rb via CI_QUEUE_LAZY_LOAD_TEST_HELPERS)
          # to boot the app for all workers.
          queue_config.lazy_load_test_helper_paths.each do |helper_path|
            require File.expand_path(helper_path)
          end
        else
          test_file_list.sort.each do |file_path|
            require File.expand_path(file_path)
          end
        end
      ensure
        @load_tests_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        @total_files = begin
          preresolved_test_list ? nil : test_file_list.size
        rescue StandardError
          nil
        end
      end

      def configure_lazy_queue
        return unless queue.respond_to?(:entry_resolver=)

        queue.entry_resolver = lazy_entry_resolver
      end

      def lazy_entry_resolver
        loader = queue.respond_to?(:file_loader) ? queue.file_loader : CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        Minitest::Queue::LazyEntryResolver.new(loader: loader, resolver: resolver)
      end

      # Reads a pre-resolved test list file (one entry per line: "TestId|file/path.rb")
      # and yields entries in the internal tab-delimited QueueEntry format.
      #
      # When --test-files is also provided, those files act as a reconcile set:
      # preresolved entries whose file path matches are skipped (they may be stale),
      # and the files are lazily discovered to enqueue their current tests.
      # This runs only on the leader (stream_populate is leader-only), so discovery
      # happens exactly once per build.
      def preresolved_entry_enumerator
        override_files = reconcile_file_set

        Enumerator.new do |yielder|
          preresolved_kept = 0
          preresolved_skipped = 0

          File.foreach(preresolved_test_list) do |line|
            line = line.chomp
            next if line.strip.empty?

            # Split on the LAST pipe — test method names can contain '|'
            # (e.g., regex patterns, boolean conditions) but file paths never do.
            test_id, _, file_path = line.rpartition('|')
            if test_id.empty?
              # No pipe found — treat the whole line as a test ID with no file path
              test_id = file_path
              file_path = nil
            end

            # Skip entries for files that will be re-discovered via --test-files
            if file_path && override_files.include?(file_path)
              preresolved_skipped += 1
              next
            end

            preresolved_kept += 1
            yielder << CI::Queue::QueueEntry.format(test_id, file_path)
          end

          if CI::Queue.debug?
            puts "[ci-queue][preresolved] kept=#{preresolved_kept} skipped=#{preresolved_skipped} " \
              "reconcile_files=#{override_files.size}"
          end

          # Lazily discover current tests for each reconciled file
          unless override_files.empty?
            discovery_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            discovered = 0
            lazy_test_discovery.each_test(override_files.to_a) do |example|
              discovered += 1
              yielder << example.queue_entry
            end
            duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - discovery_start
            if CI::Queue.debug?
              puts "[ci-queue][reconcile-discovery] discovered=#{discovered} files=#{override_files.size} " \
                "duration=#{duration.round(2)}s"
            end
          end
        end
      end

      def lazy_test_discovery
        @lazy_test_discovery ||= begin
          loader = queue.respond_to?(:file_loader) ? queue.file_loader : CI::Queue::FileLoader.new
          Minitest::Queue::LazyTestDiscovery.new(loader: loader, resolver: CI::Queue::ClassResolver)
        end
      end

      # In preresolved mode, --test-files provides the reconcile set: test files
      # whose preresolved entries should be discarded and re-discovered.
      # Returns an empty Set if no test files file is provided.
      def reconcile_file_set
        return Set.new unless test_files_file
        return Set.new unless File.exist?(test_files_file)

        Set.new(File.readlines(test_files_file, chomp: true).reject(&:empty?))
      end

      def lazy_test_enumerator
        loader = queue.respond_to?(:file_loader) ? queue.file_loader : CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        files = test_file_list.sort

        Minitest::Queue::LazyTestDiscovery.new(loader: loader, resolver: resolver).enumerator(files)
      end

      # Returns the list of test files to process. Prefers --test-files FILE
      # (reads paths from a file, one per line) over positional argv arguments.
      # --test-files avoids ARG_MAX limits for large test suites (36K+ files).
      def test_file_list
        @test_file_list ||= begin
          if test_files_file
            File.readlines(test_files_file, chomp: true).reject { |f| f.strip.empty? }
          else
            argv
          end
        end
      end
    end
  end
end
