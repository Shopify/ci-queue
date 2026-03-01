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
        @out.puts "  %-12s %-12s %8s %14s %14s %14s %14s %10s" % ['Worker', 'Role', 'Tests', '1st Test', 'Wall Clock', 'Load Tests', 'File Load', 'Memory']
        @out.puts "  #{'-' * 100}"

        sorted.each do |profile|
          @out.puts format_profile_row(profile)
        end

        print_first_test_summary(sorted)
      rescue StandardError
        # Don't fail the build if profile printing fails
      end

      private

      def format_profile_row(profile)
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
