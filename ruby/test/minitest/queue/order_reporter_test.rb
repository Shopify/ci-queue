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
        pid = fork do
          @reporter.start
        end
        pids = 5.times.map do
          fork do
            @reporter.before_test(runnable(Process.pid))
            @reporter.report
          end
        end
        (pids + [pid]).map do |pid|
          Process.waitpid(pid)
        end

        assert_equal pids.map { |pid| "Minitest::Test##{pid}" }.sort, File.readlines(log_path).map(&:chomp).sort
      end
    end

    private

    def delete_log
      File.delete(log_path) if File.exists?(log_path)
    end

    def log_path
      @path ||= File.join(Dir.tmpdir, 'test_order.log')
    end
  end
end
