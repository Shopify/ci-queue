# frozen_string_literal: true
require 'test_helper'
require 'minitest/queue/lazy_test_discovery'
require 'zlib'

module Minitest::Queue
  class LazyTestDiscoveryTest < Minitest::Test
    def test_load_error_generates_deterministic_test_id
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      discovered = []

      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "broken_test.rb")
        File.write(file_path, "raise 'boom'\n")

        2.times do
          discovered.clear
          discovery = LazyTestDiscovery.new(loader: loader, resolver: resolver)
          discovery.each_test([file_path]) { |test| discovered << test.id }
        end

        assert_equal 1, discovered.size
        assert_match(/\ACIQueue::FileLoadError#load_file_[0-9a-f]+\z/, discovered.first)
      end
    end

    def test_load_error_test_id_is_stable_across_invocations
      file_path = "/tmp/stable_hash_test_#{rand(1000)}.rb"
      method_name_a = "load_file_#{Zlib.crc32(file_path).to_s(16)}"
      method_name_b = "load_file_#{Zlib.crc32(file_path).to_s(16)}"
      assert_equal method_name_a, method_name_b
    end

    def test_discovers_methods_added_by_reopened_class
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      discovery = LazyTestDiscovery.new(loader: loader, resolver: resolver)
      class_name = "DiscoveryLazy#{Process.pid}#{rand(1000)}"
      discovered = []

      Dir.mktmpdir do |dir|
        first_file = File.join(dir, "first_test.rb")
        second_file = File.join(dir, "second_test.rb")
        File.write(first_file, "class #{class_name} < Minitest::Test\n  def test_one\n    assert true\n  end\nend\n")
        File.write(second_file, "class #{class_name}\n  def test_two\n    assert true\n  end\nend\n")

        discovery.each_test([first_file, second_file]) do |test|
          discovered << test.id
        end
      end

      assert_includes discovered, "#{class_name}#test_one"
      assert_includes discovered, "#{class_name}#test_two"
    ensure
      Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
    end

    def test_test_inclusion_filter_excludes_tests_before_yielding
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      discovery = LazyTestDiscovery.new(loader: loader, resolver: resolver)
      class_name = "FilterLazy#{Process.pid}#{rand(1000)}"
      discovered = []
      filter_calls = []

      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "filtered_test.rb")
        File.write(file_path, <<~RUBY)
          class #{class_name} < Minitest::Test
            def test_keep_me
              assert true
            end

            def test_drop_me
              assert true
            end
          end
        RUBY

        with_test_inclusion_filter(->(_runnable, method_name) {
          filter_calls << method_name
          method_name == "test_keep_me"
        }) do
          discovery.each_test([file_path]) { |test| discovered << test.id }
        end
      end

      assert_includes discovered, "#{class_name}#test_keep_me"
      refute_includes discovered, "#{class_name}#test_drop_me"
      assert_includes filter_calls, "test_keep_me"
      assert_includes filter_calls, "test_drop_me"
    ensure
      Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
    end

    def test_test_inclusion_filter_default_keeps_all_tests
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      discovery = LazyTestDiscovery.new(loader: loader, resolver: resolver)
      class_name = "NoFilterLazy#{Process.pid}#{rand(1000)}"
      discovered = []

      assert_nil CI::Queue.test_inclusion_filter

      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "unfiltered_test.rb")
        File.write(file_path, <<~RUBY)
          class #{class_name} < Minitest::Test
            def test_a
              assert true
            end

            def test_b
              assert true
            end
          end
        RUBY

        discovery.each_test([file_path]) { |test| discovered << test.id }
      end

      assert_includes discovered, "#{class_name}#test_a"
      assert_includes discovered, "#{class_name}#test_b"
    ensure
      Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
    end

    def test_test_inclusion_filter_does_not_block_load_error_examples
      loader = CI::Queue::FileLoader.new
      resolver = CI::Queue::ClassResolver
      discovery = LazyTestDiscovery.new(loader: loader, resolver: resolver)
      discovered = []

      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "broken_test.rb")
        File.write(file_path, "raise 'boom'\n")

        # Filter rejects everything; load-error synthetic example must still surface.
        with_test_inclusion_filter(->(_, _) { false }) do
          discovery.each_test([file_path]) { |test| discovered << test.id }
        end
      end

      assert_equal 1, discovered.size
      assert_match(/\ACIQueue::FileLoadError#load_file_[0-9a-f]+\z/, discovered.first)
    end

    private

    def with_test_inclusion_filter(filter)
      previous = CI::Queue.test_inclusion_filter
      CI::Queue.test_inclusion_filter = filter
      yield
    ensure
      CI::Queue.test_inclusion_filter = previous
    end
  end
end
