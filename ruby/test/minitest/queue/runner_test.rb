# frozen_string_literal: true
require 'minitest/queue/runner'
require 'test_helper'

module Minitest::Queue
  class RunnerTest < Minitest::Test
    def test_multiple_load_paths
      runner = Runner.new(["-Ilib:test", "-Ielse"])
      assert_equal("lib:test:else", runner.send(:load_paths))
    end
  end
end
