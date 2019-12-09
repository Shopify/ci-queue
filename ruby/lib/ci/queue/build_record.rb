# frozen_string_literal: true
module CI
  module Queue
    class BuildRecord
      attr_reader :error_reports

      def initialize(queue)
        @queue = queue
        @error_reports = {}
        @stats = {}
      end

      def progress
        @queue.progress
      end

      def queue_exhausted?
        @queue.exhausted?
      end

      def record_error(id, payload, stats: nil)
        error_reports[id] = payload
        record_stats(stats)
      end

      def record_success(id, stats: nil)
        error_reports.delete(id)
        record_stats(stats)
      end

      def fetch_stats(stat_names)
        stat_names.zip(stats.values_at(*stat_names).map(&:to_f))
      end

      def reset_stats(stat_names)
        stat_names.each { |s| stats.delete(s) }
      end

      private

      attr_reader :stats

      def record_stats(builds_stats)
        return unless builds_stats
        stats.merge!(builds_stats)
      end
    end
  end
end
