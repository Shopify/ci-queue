# frozen_string_literal: true

require 'minitest/queue/lazy_entry_resolver'
require 'minitest/queue/lazy_test_discovery'

module Minitest
  module Queue
    class QueuePopulationStrategy
      attr_reader :load_tests_duration, :total_files

      def initialize(queue:, queue_config:, argv:, test_files_file:, ordering_seed:)
        @queue = queue
        @queue_config = queue_config
        @argv = argv
        @test_files_file = test_files_file
        @ordering_seed = ordering_seed
      end

      def load_and_populate!
        load_tests
        populate_queue
      end

      private

      attr_reader :queue, :queue_config, :argv, :test_files_file, :ordering_seed

      def populate_queue
        if queue_config.lazy_load && queue.respond_to?(:stream_populate)
          configure_lazy_queue
          queue.stream_populate(lazy_test_enumerator, random: ordering_seed, batch_size: queue_config.lazy_load_stream_batch_size)
        else
          queue.populate(Minitest.loaded_tests, random: ordering_seed)
        end
      end

      def load_tests
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if queue_config.lazy_load && queue.respond_to?(:stream_populate)
          # In lazy-load mode, test files are loaded on-demand by the entry resolver.
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
          test_file_list.size
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
