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
