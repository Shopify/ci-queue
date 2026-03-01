# frozen_string_literal: true
require 'test_helper'

module Minitest::Queue
  class LazySingleExampleTest < Minitest::Test
    def test_run_executes_test
      Dir.mktmpdir do |dir|
        class_name = "LazyExample#{Process.pid}#{rand(1000)}"
        file_path = File.join(dir, "lazy_example_test.rb")
        File.write(
          file_path,
          "class #{class_name} < Minitest::Test\n" \
          "  def test_works\n" \
          "    assert true\n" \
          "  end\n" \
          "end\n"
        )

        loader = CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        example = LazySingleExample.new(class_name, 'test_works', file_path, loader: loader, resolver: resolver)

        result = example.run

        assert result.passed?
        assert_equal [file_path, 2], example.source_location
      ensure
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
      end
    end

    def test_run_returns_error_for_load_error
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      error = StandardError.new('boom')
      example = LazySingleExample.new('MissingClass', 'test_missing', '/tmp/missing.rb', loader: loader, resolver: resolver, load_error: error)

      result = example.run

      assert result.error?
      assert_instance_of Minitest::UnexpectedError, result.failure
      assert_nil example.source_location
    end

    def test_run_handles_script_error
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      example = LazySingleExample.new('MissingClass', 'test_missing', '/tmp/missing.rb', loader: loader, resolver: resolver)

      example.stub(:runnable, -> { raise LoadError, 'boom' }) do
        result = example.run
        assert result.error?
        assert_instance_of Minitest::UnexpectedError, result.failure
      end
    end

    def test_run_skips_stale_entry_when_skip_stale_tests_enabled
      Dir.mktmpdir do |dir|
        class_name = "StaleEntry#{Process.pid}#{rand(1000)}"
        file_path = File.join(dir, "stale_entry_test.rb")
        File.write(
          file_path,
          "class #{class_name} < Minitest::Test\n" \
          "  def test_exists\n" \
          "    assert true\n" \
          "  end\n" \
          "end\n"
        )

        loader = CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        example = LazySingleExample.new(class_name, 'test_no_longer_exists', file_path, loader: loader, resolver: resolver)

        old_queue = Minitest.queue
        Minitest.queue = Struct.new(:config).new(CI::Queue::Configuration.new(skip_stale_tests: true))

        result = example.run

        assert result.skipped?
        assert_match(/Stale preresolved entry/, result.failure.message)
        assert_match(/test_no_longer_exists/, result.failure.message)
      ensure
        Minitest.queue = old_queue
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
      end
    end

    def test_run_errors_on_stale_entry_when_skip_stale_tests_disabled
      Dir.mktmpdir do |dir|
        class_name = "StaleNoSkip#{Process.pid}#{rand(1000)}"
        file_path = File.join(dir, "stale_no_skip_test.rb")
        File.write(
          file_path,
          "class #{class_name} < Minitest::Test\n" \
          "  def test_exists\n" \
          "    assert true\n" \
          "  end\n" \
          "end\n"
        )

        loader = CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        example = LazySingleExample.new(class_name, 'test_no_longer_exists', file_path, loader: loader, resolver: resolver)

        old_queue = Minitest.queue
        Minitest.queue = Struct.new(:config).new(CI::Queue::Configuration.new(skip_stale_tests: false))

        result = example.run

        assert result.error?
      ensure
        Minitest.queue = old_queue
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
      end
    end

    def test_marshal_round_trip
      Dir.mktmpdir do |dir|
        class_name = "LazyMarshal#{Process.pid}#{rand(1000)}"
        file_path = File.join(dir, "lazy_marshal_test.rb")
        File.write(
          file_path,
          "class #{class_name} < Minitest::Test\n" \
          "  def test_works\n" \
          "    assert true\n" \
          "  end\n" \
          "end\n"
        )

        loader = CI::Queue::FileLoader.new
        resolver = CI::Queue::ClassResolver
        example = LazySingleExample.new(class_name, 'test_works', file_path, loader: loader, resolver: resolver)
        dumped = Marshal.dump(example)
        loaded = Marshal.load(dumped)

        assert_equal example.queue_entry, loaded.queue_entry
        assert loaded.run.passed?
      ensure
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
      end
    end
  end
end
