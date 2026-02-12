# frozen_string_literal: true

require 'set'

module Minitest
  module Queue
    class LazyTestDiscovery
      def initialize(loader:, resolver:)
        @loader = loader
        @resolver = resolver
      end

      def enumerator(files)
        Enumerator.new do |yielder|
          each_test(files) do |test|
            yielder << test
          end
        end
      end

      def each_test(files)
        discovery_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        total_files = 0
        new_runnable_files = 0
        reopened_files = 0
        reopened_candidates = 0
        reopened_scan_time = 0.0

        seen = Set.new
        runnables = Minitest::Test.runnables
        known_count = runnables.size
        by_full_name = {}
        by_short_name = Hash.new { |h, k| h[k] = [] }
        index_runnables(runnables, by_full_name, by_short_name)

        files.each do |file|
          total_files += 1
          file_path = File.expand_path(file)
          begin
            @loader.load_file(file_path)
          rescue CI::Queue::FileLoadError => error
            method_name = "load_file_#{file_path.hash.abs}"
            class_name = "CIQueue::FileLoadError"
            test_id = "#{class_name}##{method_name}"
            entry = CI::Queue::QueueEntry.format(
              test_id,
              CI::Queue::QueueEntry.encode_load_error(file_path, error),
            )
            yield Minitest::Queue::LazySingleExample.new(
              class_name,
              method_name,
              file_path,
              loader: @loader,
              resolver: @resolver,
              load_error: error,
              queue_entry: entry,
            )
            next
          end

          runnables = Minitest::Test.runnables
          candidates = []
          if runnables.size > known_count
            new_runnables = runnables[known_count..]
            known_count = runnables.size
            index_runnables(new_runnables, by_full_name, by_short_name)
            candidates.concat(new_runnables)
            new_runnable_files += 1
          else
            # Re-opened classes do not increase runnables size. In that case, map
            # declared class names in the file to known runnables directly.
            reopened_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            reopened = reopened_runnables_for_file(file_path, by_full_name, by_short_name)
            reopened_scan_time += Process.clock_gettime(Process::CLOCK_MONOTONIC) - reopened_start
            unless reopened.empty?
              reopened_files += 1
              reopened_candidates += reopened.size
            end
            candidates.concat(reopened)
          end

          enqueue_discovered_tests(candidates.uniq, file_path, seen) do |test|
            yield test
          end
        end
      ensure
        debug_discovery_profile(
          discovery_start: discovery_start,
          total_files: total_files,
          new_runnable_files: new_runnable_files,
          reopened_files: reopened_files,
          reopened_candidates: reopened_candidates,
          reopened_scan_time: reopened_scan_time,
        )
      end

      private

      def reopened_runnables_for_file(file_path, by_full_name, by_short_name)
        declared = declared_class_names(file_path)
        return [] if declared.empty?

        declared.each_with_object([]) do |name, runnables|
          runnable = by_full_name[name]
          if runnable
            runnables << runnable
            next
          end

          short_name = name.split('::').last
          runnables.concat(by_short_name[short_name])
        end
      end

      def index_runnables(runnables, by_full_name, by_short_name)
        runnables.each do |runnable|
          name = runnable.name
          next unless name

          by_full_name[name] ||= runnable
          short_name = name.split('::').last
          by_short_name[short_name] << runnable
        end
      end

      def debug_discovery_profile(discovery_start:, total_files:, new_runnable_files:, reopened_files:, reopened_candidates:, reopened_scan_time:)
        return unless CI::Queue.debug?

        total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - discovery_start
        puts "[ci-queue][lazy-discovery] files=#{total_files} new_runnable_files=#{new_runnable_files} " \
          "reopened_files=#{reopened_files} reopened_candidates=#{reopened_candidates} " \
          "reopened_scan_time=#{reopened_scan_time.round(2)}s total_time=#{total_time.round(2)}s"
      end

      def enqueue_discovered_tests(runnables, file_path, seen)
        runnables.each do |runnable|
          runnable.runnable_methods.each do |method_name|
            test_id = "#{runnable.name}##{method_name}"
            next if seen.include?(test_id)

            seen.add(test_id)
            yield Minitest::Queue::LazySingleExample.new(
              runnable.name,
              method_name,
              file_path,
              loader: @loader,
              resolver: @resolver,
            )
          rescue NameError, NoMethodError
            next
          end
        end
      end

      def declared_class_names(file_path)
        names = Set.new
        ::File.foreach(file_path) do |line|
          match = line.match(/^\s*class\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/)
          names.add(match[1]) if match
        end
        names
      rescue SystemCallError
        Set.new
      end

    end
  end
end
