# frozen_string_literal: true

require 'set'

module CI
  module Queue
    class FileLoader
      attr_reader :load_stats

      def initialize
        @loaded_files = Set.new
        @failed_files = {}
        @pid = Process.pid
        @forked = false
        @load_stats = {}
        @loaded_features = nil
      end

      def load_file(file_path)
        detect_fork!
        expanded = ::File.expand_path(file_path)
        return if @loaded_files.include?(expanded)

        if (cached_error = @failed_files[expanded])
          raise cached_error
        end

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil

        begin
          required = with_warning_suppression { require expanded }
          if should_force_load_after_fork?(required, expanded)
            with_warning_suppression { load expanded }
          end
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          error = e
        ensure
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          @load_stats[expanded] = duration
        end

        if error
          load_error = FileLoadError.new(file_path, error)
          @failed_files[expanded] = load_error
          raise load_error
        end

        remember_loaded_feature(expanded)
        @loaded_files.add(expanded)
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
        @failed_files.clear
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
