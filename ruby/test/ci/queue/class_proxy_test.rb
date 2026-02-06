# frozen_string_literal: true
require 'test_helper'
require 'tempfile'

module CI
  module Queue
    class ClassProxyTest < Minitest::Test
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
        # Use a real file so load_test_file doesn't raise LoadError
        test_file = create_test_file('MarshalFilePathTest', 'class MarshalFilePathTest; end')
        proxy = ClassProxy.new('MarshalFilePathTest', file_path: test_file.path)

        marshaled = Marshal.dump(proxy)
        unmarshaled = Marshal.load(marshaled)

        assert_equal 'MarshalFilePathTest', unmarshaled.name
      ensure
        remove_const_if_defined(:MarshalFilePathTest)
        test_file&.unlink
      end

      def test_lazy_loads_file_when_constant_not_found
        test_file = create_test_file('LazyLoadTest', 'class LazyLoadTest; end')

        # Create proxy before class is loaded
        proxy = ClassProxy.new('LazyLoadTest', file_path: test_file.path)

        # Accessing proxy should trigger file load
        assert_equal 'LazyLoadTest', proxy.name
      ensure
        remove_const_if_defined(:LazyLoadTest)
        test_file&.unlink
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
        test_file = create_test_file('WrongClassProxy', 'class WrongClassProxy; end')

        proxy = ClassProxy.new('ExpectedClass', file_path: test_file.path)

        error = assert_raises(NameError) do
          proxy.name
        end

        assert_match(/ExpectedClass not found after loading/, error.message)
        assert_match(/#{Regexp.escape(test_file.path)}/, error.message)
      ensure
        remove_const_if_defined(:WrongClassProxy)
        test_file&.unlink
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
      ensure
        remove_const_if_defined(:ThreadSafeClass)
        test_file&.unlink
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
      ensure
        remove_const_if_defined(:Nested)
        test_file&.unlink
      end

      private

      def create_test_file(class_name, content)
        file = Tempfile.new(['test_class', '.rb'])
        file.write(content)
        file.close
        file
      end

      def remove_const_if_defined(const_name)
        Object.send(:remove_const, const_name) if Object.const_defined?(const_name)
      rescue NameError
        # Ignore - constant may not be at top level
      end
    end
  end
end
