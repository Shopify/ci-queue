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
        seen = Set.new
        known_count = Minitest::Test.runnables.size

        files.each do |file|
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
            candidates.concat(new_runnables)
          end

          candidates.concat(reopened_runnables_for_file(runnables, file_path))
          enqueue_discovered_tests(candidates.uniq, file_path, seen) do |test|
            yield test
          end
        end
      end

      private

      def reopened_runnables_for_file(runnables, file_path)
        declared = declared_class_names(file_path)
        return [] if declared.empty?

        declared_short = declared.map { |name| name.split('::').last }.to_set

        runnables.select do |runnable|
          name = runnable.name
          next false unless name
          next false unless declared.include?(name) || declared_short.include?(name.split('::').last)

          runnable_has_method_in_file?(runnable, file_path)
        end
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

      def runnable_has_method_in_file?(runnable, file_path)
        runnable.runnable_methods.any? do |method_name|
          location = runnable.instance_method(method_name).source_location
          location && ::File.expand_path(location.first) == file_path
        rescue NameError
          false
        end
      end
    end
  end
end
