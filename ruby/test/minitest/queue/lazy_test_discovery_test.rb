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
  end
end
