# frozen_string_literal: true
require 'test_helper'

class CI::Queue::ClassResolverTest < Minitest::Test
  def test_resolves_fully_qualified_class
    resolver_test = Module.new
    inner = Module.new
    foo_class = Class.new
    inner.const_set(:FooTest, foo_class)
    resolver_test.const_set(:Inner, inner)
    Object.const_set(:ResolverTest, resolver_test)

    klass = CI::Queue::ClassResolver.resolve("ResolverTest::Inner::FooTest")
    assert_equal ResolverTest::Inner::FooTest, klass
  ensure
    if Object.const_defined?(:ResolverTest)
      ResolverTest::Inner.send(:remove_const, :FooTest) if ResolverTest::Inner.const_defined?(:FooTest)
      ResolverTest.send(:remove_const, :Inner) if ResolverTest.const_defined?(:Inner)
      Object.send(:remove_const, :ResolverTest)
    end
  end

  def test_does_not_leak_to_top_level_const
    resolver_test = Module.new
    resolver_test.const_set(:Inner, Module.new)
    Object.const_set(:ResolverTest, resolver_test)

    Object.const_set(:FooTest, Class.new)

    assert_raises(CI::Queue::ClassNotFoundError) do
      CI::Queue::ClassResolver.resolve("ResolverTest::Inner::FooTest")
    end
  ensure
    Object.send(:remove_const, :FooTest) if Object.const_defined?(:FooTest)
    if Object.const_defined?(:ResolverTest)
      ResolverTest.send(:remove_const, :Inner) if ResolverTest.const_defined?(:Inner)
      Object.send(:remove_const, :ResolverTest)
    end
  end

  def test_raises_for_module
    resolver_test = Module.new
    resolver_test.const_set(:OnlyModule, Module.new)
    Object.const_set(:ResolverTest, resolver_test)

    assert_raises(CI::Queue::ClassNotFoundError) do
      CI::Queue::ClassResolver.resolve("ResolverTest::OnlyModule")
    end
  ensure
    if Object.const_defined?(:ResolverTest)
      ResolverTest.send(:remove_const, :OnlyModule) if ResolverTest.const_defined?(:OnlyModule)
      Object.send(:remove_const, :ResolverTest)
    end
  end

  def test_resolves_with_loader
    Object.send(:remove_const, :ResolverLoaded) if Object.const_defined?(:ResolverLoaded)

    loader = Class.new do
      def load_file(_path)
        Object.const_set(:ResolverLoaded, Class.new)
      end
    end.new

    klass = CI::Queue::ClassResolver.resolve("ResolverLoaded", file_path: "./dummy", loader: loader)
    assert_equal ResolverLoaded, klass
  ensure
    Object.send(:remove_const, :ResolverLoaded) if Object.const_defined?(:ResolverLoaded)
  end
end
