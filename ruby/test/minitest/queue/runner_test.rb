# frozen_string_literal: true
require 'minitest/queue/runner'
require 'test_helper'

module Minitest::Queue
  class RunnerTest < Minitest::Test
    def test_multiple_load_paths
      runner = Runner.new(["-Ilib:test", "-Ielse"])
      assert_equal("lib:test:else", runner.send(:load_paths))
    end

    def test_validate_file_affinity_noop_when_flag_off
      runner = build_runner_with_distributed_queue(file_affinity: false)
      runner.validate_file_affinity!
      pass
    end

    def test_validate_file_affinity_passes_with_run_command_and_distributed_queue
      runner = build_runner_with_distributed_queue(file_affinity: true, command: 'run')
      runner.validate_file_affinity!
      pass
    end

    def test_validate_file_affinity_rejects_non_distributed_queue
      runner = build_runner_with_static_queue(file_affinity: true, command: 'run')
      assert_invalid_usage(/Redis queue/) { runner.validate_file_affinity! }
    end

    def test_validate_file_affinity_rejects_preresolved
      runner = build_runner_with_distributed_queue(file_affinity: true, command: 'run')
      runner.send(:preresolved_test_list=, '/tmp/preresolved.txt')
      assert_invalid_usage(/--preresolved-tests/) { runner.validate_file_affinity! }
    end

    def test_validate_file_affinity_rejects_grind
      runner = build_runner_with_distributed_queue(file_affinity: true, command: 'run')
      runner.send(:queue_config).grind_count = 5
      assert_invalid_usage(/grind/) { runner.validate_file_affinity! }
    end

    def test_validate_file_affinity_rejects_bisect
      runner = build_runner_with_distributed_queue(file_affinity: true, command: 'run')
      runner.send(:queue_config).failing_test = 'FooTest#test_bar'
      assert_invalid_usage(/bisect/) { runner.validate_file_affinity! }
    end

    def test_validate_file_affinity_rejects_non_run_command
      runner = build_runner_with_distributed_queue(file_affinity: true, command: 'report')
      assert_invalid_usage(/run.*subcommand/) { runner.validate_file_affinity! }
    end

    private

    def build_runner_with_distributed_queue(file_affinity:, command: nil)
      runner = Runner.new([])
      config = CI::Queue::Configuration.new(file_affinity: file_affinity)
      runner.instance_variable_set(:@queue_config, config)
      runner.instance_variable_set(:@command, command) if command
      queue = Object.new
      def queue.distributed?; true; end
      runner.instance_variable_set(:@queue, queue)
      runner
    end

    def build_runner_with_static_queue(file_affinity:, command: nil)
      runner = build_runner_with_distributed_queue(file_affinity: file_affinity, command: command)
      queue = Object.new
      def queue.distributed?; false; end
      runner.instance_variable_set(:@queue, queue)
      runner
    end

    def assert_invalid_usage(pattern)
      raised = nil
      runner_class = Runner
      runner_class.class_eval do
        alias_method :__orig_invalid_usage!, :invalid_usage!
        define_method(:invalid_usage!) { |msg| raise InvalidUsageStub.new(msg) }
      end
      yield
      flunk "expected invalid_usage! to be called"
    rescue InvalidUsageStub => e
      raised = e
      assert_match pattern, raised.message
    ensure
      runner_class.class_eval do
        alias_method :invalid_usage!, :__orig_invalid_usage!
        remove_method :__orig_invalid_usage!
      end
    end

    class InvalidUsageStub < StandardError; end
  end
end
