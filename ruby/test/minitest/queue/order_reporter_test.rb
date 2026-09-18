# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class OrderReporterTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @reporter = OrderReporter.new(path: log_path)
    end

    def test_start
      @reporter.start
      @reporter.report
      assert_equal [], File.readlines(log_path).map(&:chomp)
    end

    def test_before_test
      @reporter.start
      @reporter.before_test(runnable('a'))
      @reporter.before_test(runnable('b'))
      @reporter.report
      assert_equal ['Minitest::Test#a', 'Minitest::Test#b'], File.readlines(log_path).map(&:chomp)
    end

    unless truffleruby?
      def test_forking
        # `start` truncates the log. In production it runs in the parent before
        # workers fork; wait for it here so the truncate can't race the appends.
        Process.waitpid(fork { @reporter.start })
        pids = 5.times.map do
          fork do
            @reporter.before_test(runnable(Process.pid))
            @reporter.report
          end
        end
        pids.each { |pid| Process.waitpid(pid) }

        assert_equal pids.map { |pid| "Minitest::Test##{pid}" }.sort, File.readlines(log_path).map(&:chomp).sort
      end
    end

    private

    def log_path
      @path ||= File.join(Dir.tmpdir, 'test_order.log')
    end
  end
end
