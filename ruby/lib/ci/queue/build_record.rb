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

      def record_error(id, payload)
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

      def fetch_stats(stat_names)
        stat_names.zip(stats.values_at(*stat_names).map(&:to_f))
      end

      def reset_stats(stat_names)
        stat_names.each { |s| stats.delete(s) }
      end

      def report_worker_error(_); end

      def reset_worker_error; end

      def worker_errors
        {}
      end

      def record_stats(builds_stats)
        return unless builds_stats
        stats.merge!(builds_stats)
      end

      private

      attr_reader :stats
    end
  end
end
