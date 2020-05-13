# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class RunCommandFormatterTest < Minitest::Test
    include ReporterTestHelper

    def teardown
      Minitest.run_command_formatter = Minitest::Queue::DEFAULT_RUN_COMMAND_FORMATTER
    end

    def test_default_formatter
      result = result('a', failure: "Something went wrong")

      formatter = Minitest::Queue::DEFAULT_RUN_COMMAND_FORMATTER
      command_arguments = formatter.call(result)
      assert_equal %w[bundle exec ruby -Ilib:test test/my_test.rb -n Minitest::Test#a], command_arguments
    end

    def test_rails_formatter
      result = result('a', failure: "Something went wrong")

      formatter = Minitest::Queue::RAILS_RUN_COMMAND_FORMATTER
      command_arguments = formatter.call(result)
      assert_equal %w[bin/rails test test/my_test.rb:12], command_arguments
    end

    def test_format_run_command_with_custom_formatter_returning_string
      Minitest.run_command_formatter = lambda do |result|
        "testrunner #{result.klass}##{result.name}"
      end

      command = Minitest.run_command_for_runnable(result('a'))
      assert_equal 'testrunner Minitest::Test#a', command
    end

    def test_format_run_command_with_custom_formatter_returning_array
      Minitest.run_command_formatter = lambda do |result|
        ["test runner", "#{result.klass}##{result.name}"]
      end

      command = Minitest.run_command_for_runnable(result('a'))
      assert_equal %{test\\ runner Minitest::Test\\#a}, command
    end
  end
end
