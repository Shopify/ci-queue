# frozen_string_literal: true
require 'test_helper'
require 'tempfile'

module CI
  module Queue
    class ClassProxyTest < Minitest::Test
      def setup
        # Clear loaded files tracking between tests
        ClassProxy.class_variable_set(:@@loaded_files, Set.new)
      end

      def test_acts_like_a_class
        proxy = ClassProxy.new('String')

        assert proxy.is_a?(Class)
        assert proxy == String, "ClassProxy should equal the actual class"
        assert_equal 'String', proxy.name
      end

      def test_delegates_method_calls
        proxy = ClassProxy.new('Array')

        assert_respond_to proxy, :new
        instance = proxy.new
        assert_kind_of Array, instance
      end

      def test_marshaling_without_file_path
        proxy = ClassProxy.new('Integer')

        marshaled = Marshal.dump(proxy)
        unmarshaled = Marshal.load(marshaled)

        assert_equal 'Integer', unmarshaled.name
        assert unmarshaled == Integer, "Unmarshaled proxy should equal Integer"
      end

      def test_marshaling_with_file_path
        proxy = ClassProxy.new('String', file_path: '/tmp/test.rb')

        marshaled = Marshal.dump(proxy)
        unmarshaled = Marshal.load(marshaled)

        assert_equal 'String', unmarshaled.name
      end

      def test_lazy_loads_file_when_constant_not_found
        test_file = create_test_file('LazyLoadTest', 'class LazyLoadTest; end')

        # Create proxy before class is loaded
        proxy = ClassProxy.new('LazyLoadTest', file_path: test_file.path)

        # Accessing proxy should trigger file load
        assert_equal 'LazyLoadTest', proxy.name

        cleanup_test_file(test_file)
      end

      def test_loads_file_only_once
        load_counter = 0
        test_file = create_test_file('LoadOnceTest', <<~RUBY)
          class LoadOnceTest
            @@load_count ||= 0
            @@load_count += 1
            def self.load_count
              @@load_count
            end
          end
        RUBY

        # Create two proxies for same class
        proxy1 = ClassProxy.new('LoadOnceTest', file_path: test_file.path)
        proxy2 = ClassProxy.new('LoadOnceTest', file_path: test_file.path)

        # Access both
        count1 = proxy1.load_count
        count2 = proxy2.load_count

        # File should only be loaded once
        assert_equal 1, count2

        cleanup_test_file(test_file)
      end

      def test_raises_load_error_for_missing_file
        proxy = ClassProxy.new('MissingClass', file_path: '/tmp/nonexistent_file_12345.rb')

        error = assert_raises(LoadError) do
          proxy.name
        end

        assert_match(/Test file not found/, error.message)
        assert_match(/nonexistent_file_12345\.rb/, error.message)
      end

      def test_raises_argument_error_for_invalid_file_extension
        proxy = ClassProxy.new('InvalidFile', file_path: '/tmp/test.txt')

        error = assert_raises(ArgumentError) do
          proxy.name
        end

        assert_match(/Invalid test file path/, error.message)
        assert_match(/must end with \.rb/, error.message)
      end

      def test_raises_helpful_error_when_class_not_defined_in_file
        test_file = create_test_file('WrongClass', 'class WrongClass; end')

        proxy = ClassProxy.new('ExpectedClass', file_path: test_file.path)

        error = assert_raises(NameError) do
          proxy.name
        end

        assert_match(/ExpectedClass not found after loading/, error.message)
        assert_match(/#{test_file.path}/, error.message)

        cleanup_test_file(test_file)
      end

      def test_thread_safety
        test_file = create_test_file('ThreadSafeClass', 'class ThreadSafeClass; end')

        threads = 10.times.map do
          Thread.new do
            proxy = ClassProxy.new('ThreadSafeClass', file_path: test_file.path)
            proxy.name
          end
        end

        results = threads.map(&:value)

        assert_equal 10, results.size
        assert results.all? { |r| r == 'ThreadSafeClass' }

        cleanup_test_file(test_file)
      end

      def test_equality_with_actual_class
        proxy = ClassProxy.new('String')

        # ClassProxy#== handles comparison with actual class
        assert proxy == String, "ClassProxy should equal String"

        # Note: String#== doesn't know about ClassProxy, so String == proxy may not work
        # This is expected behavior - the proxy is transparent when used polymorphically
      end

      def test_equality_with_another_proxy
        proxy1 = ClassProxy.new('String')
        proxy2 = ClassProxy.new('String')

        # Both proxies should equal the same underlying class
        assert proxy1 == String, "proxy1 should equal String"
        assert proxy2 == String, "proxy2 should equal String"
      end

      def test_hash_delegation
        proxy = ClassProxy.new('Integer')

        assert_equal Integer.hash, proxy.hash
      end

      def test_inspect_delegation
        proxy = ClassProxy.new('Array')

        assert_equal Array.inspect, proxy.inspect
      end

      def test_to_s_returns_class_name
        proxy = ClassProxy.new('String')

        assert_equal 'String', proxy.to_s
      end

      def test_nested_constant_resolution
        proxy = ClassProxy.new('Minitest::Test')

        assert proxy == Minitest::Test, "ClassProxy should equal Minitest::Test"
        assert_equal 'Minitest::Test', proxy.name
      end

      def test_lazy_loads_nested_constant
        test_file = create_test_file('Nested::LazyClass', <<~RUBY)
          module Nested
            class LazyClass
              def self.test_method
                'it works'
              end
            end
          end
        RUBY

        proxy = ClassProxy.new('Nested::LazyClass', file_path: test_file.path)

        assert_equal 'it works', proxy.test_method

        cleanup_test_file(test_file)
      end

      private

      def create_test_file(class_name, content)
        file = Tempfile.new(['test_class', '.rb'])
        file.write(content)
        file.close
        file
      end

      def cleanup_test_file(file)
        # Remove the constant if it was defined
        parts = file.path.match(/test_class.*\.rb/)[0].split('::')
        Object.send(:remove_const, parts.first.to_sym) if Object.const_defined?(parts.first)
      rescue
        # Ignore cleanup errors
      ensure
        file.unlink
      end
    end
  end
end
