# frozen_string_literal: true
require 'test_helper'
require 'minitest/queue/queue_population_strategy'

module Minitest::Queue
  class QueuePopulationStrategyTest < Minitest::Test
    class FakeQueue
      attr_accessor :entry_resolver
      attr_reader :populated_with, :streamed_with

      def initialize
        @file_loader = CI::Queue::FileLoader.new
      end

      def file_loader
        @file_loader
      end

      def populate(tests, random:)
        @populated_with = { tests: tests, random: random }
      end

      def stream_populate(tests, random:, batch_size:)
        @streamed_with = { tests: tests, random: random, batch_size: batch_size }
      end
    end

    def test_eager_mode_populates_loaded_tests
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: false)
      class_name = "StrategyEager#{Process.pid}#{rand(1000)}"
      file = nil
      strategy = QueuePopulationStrategy.new(
        queue: queue,
        queue_config: config,
        argv: nil,
        test_files_file: nil,
        ordering_seed: Random.new(123),
      )

      Dir.mktmpdir do |dir|
        file = File.join(dir, "strategy_eager_test.rb")
        File.write(file, "class #{class_name} < Minitest::Test\n  def test_strategy_eager\n    assert true\n  end\nend\n")
        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [file],
          test_files_file: nil,
          ordering_seed: Random.new(123),
        )
        strategy.load_and_populate!
      end

      assert queue.populated_with
      ids = queue.populated_with[:tests].map(&:id)
      assert_includes ids, "#{class_name}#test_strategy_eager"
      assert_nil queue.streamed_with
    ensure
      Object.send(:remove_const, class_name) if class_name && Object.const_defined?(class_name)
    end

    def test_lazy_mode_sets_resolver_and_streams
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: true, lazy_load_stream_batch_size: 7)
      strategy = QueuePopulationStrategy.new(
        queue: queue,
        queue_config: config,
        argv: [],
        test_files_file: nil,
        ordering_seed: Random.new(456),
      )

      strategy.load_and_populate!

      assert_instance_of Minitest::Queue::LazyEntryResolver, queue.entry_resolver
      assert queue.streamed_with
      assert_instance_of Enumerator, queue.streamed_with[:tests]
      assert_equal 7, queue.streamed_with[:batch_size]
      assert_nil queue.populated_with
    end
  end
end
