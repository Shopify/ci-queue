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

    # Simulates CI::Queue::Bisect — no stream_populate
    class FakeQueueWithoutStreamPopulate
      attr_accessor :entry_resolver
      attr_reader :populated_with

      def populate(tests, random:)
        @populated_with = { tests: tests, random: random }
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

    def test_eager_mode_sets_entry_resolver_as_fallback
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: false)
      class_name = "StrategyEagerResolver#{Process.pid}#{rand(1000)}"

      Dir.mktmpdir do |dir|
        file = File.join(dir, "strategy_eager_resolver_test.rb")
        File.write(file, "class #{class_name} < Minitest::Test\n  def test_resolver\n    assert true\n  end\nend\n")
        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [file],
          test_files_file: nil,
          ordering_seed: Random.new(123),
        )
        strategy.load_and_populate!
      end

      assert_instance_of Minitest::Queue::LazyEntryResolver, queue.entry_resolver,
        "eager mode should set entry_resolver as fallback for resolve_entry"
    ensure
      Object.send(:remove_const, class_name) if class_name && Object.const_defined?(class_name)
    end

    def test_preresolved_mode_streams_entries
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: true)
      test_ids = nil

      Dir.mktmpdir do |dir|
        names_file = File.join(dir, "test_names.txt")
        File.write(names_file, <<~TXT)
          FooTest#test_a|test/foo_test.rb
          BarTest#test_b|test/bar_test.rb
        TXT

        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [],
          test_files_file: nil,
          ordering_seed: Random.new(1),
          preresolved_test_list: names_file,
        )
        strategy.load_and_populate!

        # Consume the lazy enumerator while tmpdir still exists
        test_ids = queue.streamed_with[:tests].to_a.map { |e| CI::Queue::QueueEntry.test_id(e) }
      end

      assert_includes test_ids, "FooTest#test_a"
      assert_includes test_ids, "BarTest#test_b"
    end

    def test_preresolved_mode_with_test_files_reconciles_changed_tests
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: true)
      class_name = "ReconcileStrategyTest#{Process.pid}#{rand(1000)}"
      test_ids = nil

      Dir.mktmpdir do |dir|
        changed_file = File.join(dir, "changed_test.rb")
        File.write(changed_file, <<~RUBY)
          class #{class_name} < Minitest::Test
            def test_new_method
            end
          end
        RUBY

        names_file = File.join(dir, "test_names.txt")
        File.write(names_file, <<~TXT)
          UnchangedTest#test_keep|test/unchanged_test.rb
          #{class_name}#test_old_stale_name|#{changed_file}
        TXT

        # --test-files doubles as reconcile set in preresolved mode
        test_files = File.join(dir, "test_files.txt")
        File.write(test_files, "#{changed_file}\n")

        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [],
          test_files_file: test_files,
          ordering_seed: Random.new(1),
          preresolved_test_list: names_file,
        )
        strategy.load_and_populate!

        # Consume while tmpdir still exists
        test_ids = queue.streamed_with[:tests].to_a.map { |e| CI::Queue::QueueEntry.test_id(e) }
      end

      assert_includes test_ids, "UnchangedTest#test_keep"
      refute_includes test_ids, "#{class_name}#test_old_stale_name"
      assert_includes test_ids, "#{class_name}#test_new_method"
    ensure
      Object.send(:remove_const, class_name) if class_name && Object.const_defined?(class_name)
      Minitest::Test.runnables.reject! { |r| r.name == class_name }
    end

    def test_preresolved_mode_without_test_files_streams_all_entries
      queue = FakeQueue.new
      config = CI::Queue::Configuration.new(lazy_load: true)
      test_ids = nil

      Dir.mktmpdir do |dir|
        names_file = File.join(dir, "test_names.txt")
        File.write(names_file, "FooTest#test_a|test/foo_test.rb\n")

        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [],
          test_files_file: nil,
          ordering_seed: Random.new(1),
          preresolved_test_list: names_file,
        )
        strategy.load_and_populate!

        # Consume while tmpdir still exists
        test_ids = queue.streamed_with[:tests].to_a.map { |e| CI::Queue::QueueEntry.test_id(e) }
      end

      assert_includes test_ids, "FooTest#test_a"
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

    def test_lazy_mode_falls_back_to_eager_loading_when_queue_lacks_stream_populate
      queue = FakeQueueWithoutStreamPopulate.new
      config = CI::Queue::Configuration.new(lazy_load: true)
      class_name = "StrategyLazyFallback#{Process.pid}#{rand(1000)}"

      Dir.mktmpdir do |dir|
        file = File.join(dir, "strategy_lazy_fallback_test.rb")
        File.write(file, "class #{class_name} < Minitest::Test\n  def test_fallback\n    assert true\n  end\nend\n")
        strategy = QueuePopulationStrategy.new(
          queue: queue,
          queue_config: config,
          argv: [file],
          test_files_file: nil,
          ordering_seed: Random.new(123),
        )
        strategy.load_and_populate!
      end

      assert queue.populated_with, "expected populate to be called"
      ids = queue.populated_with[:tests].map(&:id)
      assert_includes ids, "#{class_name}#test_fallback",
        "lazy_load=true should not prevent test files from being loaded when stream_populate is unavailable"
    ensure
      Object.send(:remove_const, class_name) if class_name && Object.const_defined?(class_name)
    end
  end
end
