# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class OrderReporterTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @reporter = OrderReporter.new(path: log_path)
    end

    def teardown
      OrderReporter::TestOrderTracking.reset
      cleanup_worker_files
    end

    def test_start_cleans_stale_worker_files
      stale_path = worker_path(99999)
      File.write(stale_path, "stale\n")

      @reporter.start
      @reporter.report

      refute File.exist?(stale_path), "Stale worker file should be cleaned up"
    end

    def test_records_test_order_via_hook
      @reporter.start
      test_instance = Minitest::Test.new('a')
      test_instance.before_setup
      @reporter.report

      assert_equal ['Minitest::Test#a'], File.readlines(worker_path(Process.pid)).map(&:chomp)
    end

    def test_records_multiple_tests
      @reporter.start
      Minitest::Test.new('a').before_setup
      Minitest::Test.new('b').before_setup
      @reporter.report

      assert_equal ['Minitest::Test#a', 'Minitest::Test#b'], File.readlines(worker_path(Process.pid)).map(&:chomp)
    end

    def test_noop_when_not_started
      # before_setup should not fail or write when no reporter is active
      OrderReporter::TestOrderTracking.reset
      Minitest::Test.new('a').before_setup

      assert_empty Dir.glob(File.join(log_dir, "test_order.worker-*.log"))
    end

    unless truffleruby?
      def test_forked_workers_write_per_pid_files
        @reporter.start

        pids = 3.times.map do
          fork do
            Minitest::Test.new("test_#{Process.pid}").before_setup
          end
        end
        pids.each { |pid| Process.waitpid(pid) }

        @reporter.report

        pids.each do |pid|
          path = worker_path(pid)
          assert File.exist?(path), "Expected #{path} to exist"
          assert_equal ["Minitest::Test#test_#{pid}"], File.readlines(path).map(&:chomp)
        end
      end
    end

    private

    def log_dir
      @log_dir ||= Dir.tmpdir
    end

    def log_path
      @log_path ||= File.join(log_dir, 'test_order.log')
    end

    def worker_path(pid)
      File.join(log_dir, "test_order.worker-#{pid}.log")
    end

    def cleanup_worker_files
      Dir.glob(File.join(log_dir, "test_order.worker-*.log")).each do |f|
        File.delete(f)
      end
    end
  end
end
