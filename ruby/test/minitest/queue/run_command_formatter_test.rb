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

    def test_relative_path
      path = Minitest::Queue.relative_path('/home/willem/src/project/test/my_test.rb', root: '/home/willem/src/project')
      assert_equal "test/my_test.rb", path
    end

    def test_relative_path_with_wrong_base_dir
      path = Minitest::Queue.relative_path('/home/willem/src/project/test/my_test.rb', root: '/home/willem/src/other_project')
      assert_equal "../project/test/my_test.rb", path
    end

    def test_relative_path_already_relative
      path = Minitest::Queue.relative_path('./test/my_test.rb', root: '/home/willem/src/project')
      assert_equal "./test/my_test.rb", path
    end

    def test_relative_path_with_empty_path
      path = Minitest::Queue.relative_path('', root: '/home/willem/src/project')
      assert_equal "", path
    end
  end
end
