# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class LocalRequeueReporterTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @reporter = LocalRequeueReporter.new(verbose: true)
    end

    def test_message_for_requeued_failure_without_backtrace
      test = result('test_foo', requeued: true)
      test.failure.failure.set_backtrace(nil)

      message = @reporter.send(:message_for, test)

      assert_includes message, '[unknown]'
      assert_includes message, 'Failed'
    end
  end
end
