# frozen_string_literal: true

require 'set'

module CI
  module Queue
    class FileLoader
      attr_reader :load_stats

      def initialize
        @loaded_files = Set.new
        @pid = Process.pid
        @forked = false
        @load_stats = {}
        @loaded_features = nil
      end

      def load_file(file_path)
        detect_fork!
        return if @loaded_files.include?(file_path)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil

        begin
          required = require file_path
          if should_force_load_after_fork?(required, file_path)
            with_warning_suppression { load file_path }
          end
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          error = e
        ensure
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          @load_stats[file_path] = duration
        end

        raise FileLoadError.new(file_path, error) if error

        remember_loaded_feature(file_path)
        @loaded_files.add(file_path)
        nil
      end

      def total_load_time
        load_stats.values.sum
      end

      def slowest_files(limit = 10)
        load_stats.sort_by { |_, duration| -duration }.take(limit)
      end

      private

      def detect_fork!
        return if @pid == Process.pid

        @pid = Process.pid
        @forked = true
        @loaded_files.clear
        @load_stats.clear
        @loaded_features = nil
      end

      def file_in_loaded_features?(file_path)
        loaded_features.include?(::File.expand_path(file_path))
      end

      def loaded_features
        @loaded_features ||= Set.new($LOADED_FEATURES.map { |loaded| ::File.expand_path(loaded) })
      end

      def remember_loaded_feature(file_path)
        loaded_features.add(::File.expand_path(file_path))
      end

      def should_force_load_after_fork?(required, file_path)
        @forked && !required && file_in_loaded_features?(file_path)
      end

      def with_warning_suppression
        previous = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = previous
      end
    end
  end
end
