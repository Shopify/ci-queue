# frozen_string_literal: true
require 'test_helper'
require 'minitest/queue/lazy_test_discovery'

module Minitest::Queue
  class LazyTestDiscoveryTest < Minitest::Test
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
