# frozen_string_literal: true

require 'test_helper'

module Minitest::Queue
  class TestDataTest < Minitest::Test
    include ReporterTestHelper

    def test_error_location_without_backtrace
      failure = Minitest::Assertion.new('Assertion failed')
      test = result('test_foo', failure: failure)
      failure.set_backtrace(nil)

      data = TestData.new(
        test: test,
        index: 0,
        namespace: 'namespace',
        base_path: Minitest::Queue.project_root,
      ).to_h

      assert_equal 'unknown', data[:error_file_path]
      assert_equal 0, data[:error_file_number]
    end

    def test_error_location_uses_nested_exception_backtrace
      error = StandardError.new('boom')
      error.set_backtrace([
        "#{Minitest::Queue.project_root}/test/nested_error_test.rb:42:in `boom'",
      ])
      failure = Minitest::UnexpectedError.new(error)
      failure.set_backtrace(nil)
      test = result('test_foo', failure: failure)

      data = TestData.new(
        test: test,
        index: 0,
        namespace: 'namespace',
        base_path: Minitest::Queue.project_root,
      ).to_h

      assert_equal 'test/nested_error_test.rb', data[:error_file_path].to_s
      assert_equal 42, data[:error_file_number]
    end
  end
end
