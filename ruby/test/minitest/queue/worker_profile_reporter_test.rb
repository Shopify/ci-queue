# frozen_string_literal: true
require 'test_helper'
require 'stringio'
require 'minitest/queue/worker_profile_reporter'

module Minitest::Queue
  class WorkerProfileReporterTest < Minitest::Test
    def test_print_summary_is_silent_without_debug_env
      profiles = {
        '0' => { 'worker_id' => '0', 'mode' => 'lazy', 'role' => 'leader' },
      }
      supervisor = Struct.new(:workers_count, :build).new(
        1,
        Struct.new(:worker_profiles).new(profiles),
      )
      out = StringIO.new
      original = ENV['CI_QUEUE_DEBUG']
      ENV.delete('CI_QUEUE_DEBUG')

      WorkerProfileReporter.new(supervisor, out: out).print_summary

      assert_equal "", out.string
    ensure
      ENV['CI_QUEUE_DEBUG'] = original
    end

    def test_print_summary_outputs_table
      profiles = {
        '0' => {
          'worker_id' => '0',
          'mode' => 'lazy',
          'role' => 'leader',
          'tests_run' => 10,
          'time_to_first_test' => 1.2,
          'total_wall_clock' => 12.3,
          'load_tests_duration' => 0.4,
          'file_load_time' => 2.0,
          'files_loaded' => 3,
          'total_files' => 10,
          'memory_rss_kb' => 512_000,
        },
        '1' => {
          'worker_id' => '1',
          'mode' => 'lazy',
          'role' => 'non-leader',
          'tests_run' => 9,
          'time_to_first_test' => 2.2,
          'total_wall_clock' => 11.1,
        },
      }

      supervisor = Struct.new(:workers_count, :build).new(
        2,
        Struct.new(:worker_profiles).new(profiles),
      )
      out = StringIO.new

      original = ENV['CI_QUEUE_DEBUG']
      ENV['CI_QUEUE_DEBUG'] = '1'
      WorkerProfileReporter.new(supervisor, out: out).print_summary

      text = out.string
      assert_includes text, "Worker profile summary (2 workers, mode: lazy):"
      assert_includes text, "Leader time to 1st test: 1.2s"
      assert_includes text, "Avg non-leader time to 1st test: 2.2s"
    ensure
      ENV['CI_QUEUE_DEBUG'] = original
    end
  end
end
