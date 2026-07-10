# frozen_string_literal: true
require 'minitest/queue/runner'
require 'test_helper'

module Minitest::Queue
  class RunnerTest < Minitest::Test
    def test_multiple_load_paths
      runner = Runner.new(["-Ilib:test", "-Ielse"])
      assert_equal("lib:test:else", runner.send(:load_paths))
    end

    def test_max_consecutive_requeues_option
      runner = Runner.new(["--max-consecutive-requeues", "3"])
      config = runner.send(:queue_config)

      assert(config.circuit_breakers.any? do |breaker|
        breaker.is_a?(CI::Queue::CircuitBreaker::MaxConsecutiveRequeues)
      end)
    end
  end
end
