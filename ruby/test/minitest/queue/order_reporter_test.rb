# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class OrderReporterTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @reporter = OrderReporter.new(path: log_path)
      @reporter.start
    end

    def test_before_test
      @reporter.before_test(runnable('a'))
      @reporter.before_test(runnable('b'))
      @reporter.report
      assert_equal ['Minitest::Test#a', 'Minitest::Test#b'], File.readlines(log_path).map(&:chomp)
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
