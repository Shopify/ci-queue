# frozen_string_literal: true
require 'test_helper'
require 'minitest/queue/lazy_entry_resolver'

module Minitest::Queue
  class LazyEntryResolverTest < Minitest::Test
    def test_builds_lazy_single_example_for_regular_entry
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")

      resolved = LazyEntryResolver.new(loader: loader, resolver: resolver).call(entry)

      assert_instance_of Minitest::Queue::LazySingleExample, resolved
      assert_equal "FooTest#test_bar", resolved.id
      assert_equal entry, resolved.queue_entry
    end

    def test_builds_lazy_single_example_with_load_error
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      error = StandardError.new("boom")
      encoded = CI::Queue::QueueEntry.encode_load_error("/tmp/foo_test.rb", error)
      entry = CI::Queue::QueueEntry.format("FooTest#test_bar", encoded)

      resolved = LazyEntryResolver.new(loader: loader, resolver: resolver).call(entry)
      result = resolved.run

      assert_instance_of Minitest::Queue::LazySingleExample, resolved
      assert result.error?
      assert_instance_of Minitest::UnexpectedError, result.failure
    end
  end
end
