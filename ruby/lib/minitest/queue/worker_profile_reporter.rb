# frozen_string_literal: true

module Minitest
  module Queue
    class WorkerProfileReporter
      def initialize(supervisor, out: $stdout)
        @supervisor = supervisor
        @out = out
      end

      def print_summary
        return unless CI::Queue.debug?

        expected = @supervisor.workers_count
        profiles = {}
        3.times do
          profiles = @supervisor.build.worker_profiles
          break if profiles.size >= expected
          sleep 1
        end
        return if profiles.empty?

        sorted = profiles.values.sort_by { |p| p['worker_id'].to_s }
        mode = sorted.first&.dig('mode') || 'unknown'

        @out.puts
        @out.puts "Worker profile summary (#{sorted.size} workers, mode: #{mode}):"

        if mode == 'file_affinity'
          print_file_affinity_table(sorted)
          print_first_test_summary(sorted)
          print_file_affinity_aggregates(sorted)
        else
          print_classic_table(sorted)
          print_first_test_summary(sorted)
        end
      rescue StandardError
        # Don't fail the build if profile printing fails
      end

      private

      def print_classic_table(sorted)
        @out.puts "  %-12s %-12s %8s %14s %14s %14s %14s %10s" % ['Worker', 'Role', 'Tests', '1st Test', 'Wall Clock', 'Load Tests', 'File Load', 'Memory']
        @out.puts "  #{'-' * 100}"
        sorted.each { |profile| @out.puts format_classic_row(profile) }
      end

      def print_file_affinity_table(sorted)
        @out.puts "  %-12s %-12s %6s %8s %14s %14s %12s %10s" % ['Worker', 'Role', 'Files', 'Tests', '1st Test', 'Wall Clock', 'File P95', 'Memory']
        @out.puts "  #{'-' * 100}"
        sorted.each { |profile| @out.puts format_file_affinity_row(profile) }
      end

      def format_classic_row(profile)
        tests = profile['tests_run'] ? profile['tests_run'].to_s : 'n/a'
        first_test = profile['time_to_first_test'] ? "#{profile['time_to_first_test']}s" : 'n/a'
        wall = "#{profile['total_wall_clock']}s"
        load_tests = profile['load_tests_duration'] ? "#{profile['load_tests_duration']}s" : 'n/a'
        files = if profile['files_loaded'] && profile['total_files']
          "#{profile['file_load_time']}s (#{profile['files_loaded']}/#{profile['total_files']})"
        elsif profile['file_load_time']
          "#{profile['file_load_time']}s"
        else
          'n/a'
        end
        mem = profile['memory_rss_kb'] ? "#{(profile['memory_rss_kb'] / 1024.0).round(0)} MB" : 'n/a'

        "  %-12s %-12s %8s %14s %14s %14s %14s %10s" % [
          profile['worker_id'], profile['role'], tests, first_test, wall, load_tests, files, mem
        ]
      end

      def format_file_affinity_row(profile)
        files_run = profile['files_run'] ? profile['files_run'].to_s : 'n/a'
        # tests_discovered is the cluster-wide counter snapshotted by this
        # worker at exit time, not strictly per-worker. It still gives a
        # useful proxy: if a worker's snapshot is much lower than the final
        # value, it finished early.
        tests = profile['tests_discovered'] ? profile['tests_discovered'].to_s : 'n/a'
        first_test = profile['time_to_first_test'] ? "#{profile['time_to_first_test']}s" : 'n/a'
        wall = "#{profile['total_wall_clock']}s"
        timings = profile['file_timings_ms'] || []
        p95 = timings.empty? ? 'n/a' : "#{(percentile(timings, 95) / 1000.0).round(2)}s"
        mem = profile['memory_rss_kb'] ? "#{(profile['memory_rss_kb'] / 1024.0).round(0)} MB" : 'n/a'

        "  %-12s %-12s %6s %8s %14s %14s %12s %10s" % [
          profile['worker_id'], profile['role'], files_run, tests, first_test, wall, p95, mem
        ]
      end

      # Aggregate per-file timings across all workers and surface the headline
      # file-affinity metrics: cluster-wide P50/P95/P99, total files run, top
      # slow files. This is the data that actually justifies file-affinity
      # vs lazy mode for the bake-off.
      def print_file_affinity_aggregates(sorted)
        all_timings_ms = sorted.flat_map { |p| p['file_timings_ms'] || [] }
        return if all_timings_ms.empty?

        @out.puts
        @out.puts "  File-affinity aggregates:"
        @out.puts "    Files run total:     %d" % all_timings_ms.size
        if (discovered = sorted.last&.dig('tests_discovered'))
          @out.puts "    Tests discovered:    %d" % discovered
        end
        p50 = (percentile(all_timings_ms, 50) / 1000.0).round(2)
        p95 = (percentile(all_timings_ms, 95) / 1000.0).round(2)
        p99 = (percentile(all_timings_ms, 99) / 1000.0).round(2)
        max = (all_timings_ms.max.to_f / 1000.0).round(2)
        @out.puts "    Per-file wall clock: P50=%.2fs  P95=%.2fs  P99=%.2fs  max=%.2fs" % [p50, p95, p99, max]

        slow_files = collect_top_slow_files(sorted, limit: 10)
        return if slow_files.empty?

        @out.puts "    Slowest files:"
        slow_files.each do |path, dur|
          @out.puts "      %6.2fs  %s" % [dur, Minitest::Queue.relative_path(path)]
        end
      end

      def collect_top_slow_files(sorted, limit:)
        # Each worker's slow_files is already sorted descending by duration.
        # Merge across workers and keep the top N globally. Since per-worker
        # caps are bounded (default 100), this is cheap.
        all = sorted.flat_map { |p| p['slow_files'] || [] }
        all.sort_by! { |_, dur| -dur }
        all.first(limit)
      end

      # Linear-interp percentile over an unsorted numeric array. Cheap; we
      # only call this on per-build cluster aggregates.
      def percentile(values, pct)
        return 0 if values.nil? || values.empty?
        sorted = values.sort
        rank = (pct / 100.0) * (sorted.size - 1)
        lower = sorted[rank.floor]
        upper = sorted[rank.ceil]
        weight = rank - rank.floor
        lower + (upper - lower) * weight
      end

      def print_first_test_summary(sorted)
        leaders = sorted.select { |p| p['role'] == 'leader' }
        non_leaders = sorted.select { |p| p['role'] == 'non-leader' }
        return unless leaders.any? && non_leaders.any?

        leader_first = leaders.filter_map { |p| p['time_to_first_test'] }.min
        nl_firsts = non_leaders.filter_map { |p| p['time_to_first_test'] }
        return unless leader_first && nl_firsts.any?

        avg_nl = (nl_firsts.sum / nl_firsts.size).round(2)
        @out.puts
        @out.puts "  Leader time to 1st test: #{leader_first}s"
        @out.puts "  Avg non-leader time to 1st test: #{avg_nl}s"
      end
    end
  end
end
