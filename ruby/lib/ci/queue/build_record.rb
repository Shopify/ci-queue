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

      def record_error(id, payload, stat_delta: nil)
        error_reports[id] = payload
        true
      end

      def record_success(id, skip_flaky_record: false, acknowledge: true)
        error_reports.delete(id)
        true
      end

      def record_requeue(id)
        true
      end

      def record_stats(builds_stats)
        return unless builds_stats
        stats.merge!(builds_stats)
      end

      def record_stats_delta(delta, pipeline: nil)
        return if delta.nil? || delta.empty?
        delta.each do |stat_name, value|
          next unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+\.?\d*\z/)
          stats[stat_name] = (stats[stat_name] || 0).to_f + value.to_f
        end
      end

      def fetch_stats(stat_names)
        stat_names.zip(stats.values_at(*stat_names).map(&:to_f)).to_h
      end

      def reset_stats(stat_names)
        stat_names.each { |s| stats.delete(s) }
      end

      def report_worker_error(_); end

      def reset_worker_error; end

      def worker_errors
        {}
      end

      private

      attr_reader :stats
    end
  end
end
