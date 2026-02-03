# frozen_string_literal: true

require 'test_helper'

module CI::Queue
  class LazyLoaderTest < Minitest::Test
    def setup
      @loader = LazyLoader.new
    end

    # === Initialization ===

    def test_initializes_with_empty_loaded_files
      assert_empty @loader.loaded_files
    end

    def test_initializes_with_zero_files_loaded_count
      assert_equal 0, @loader.files_loaded_count
    end

    # === parse_test_id ===

    def test_parse_test_id_simple_class
      class_name, method_name = LazyLoader.parse_test_id('FooTest#test_bar')
      assert_equal 'FooTest', class_name
      assert_equal 'test_bar', method_name
    end

    def test_parse_test_id_namespaced_class
      class_name, method_name = LazyLoader.parse_test_id('Foo::Bar::BazTest#test_something')
      assert_equal 'Foo::Bar::BazTest', class_name
      assert_equal 'test_something', method_name
    end

    def test_parse_test_id_with_hash_in_method_name
      class_name, method_name = LazyLoader.parse_test_id('FooTest#test_with#hash')
      assert_equal 'FooTest', class_name
      assert_equal 'test_with#hash', method_name
    end

    # === build_test_id ===

    def test_build_test_id
      assert_equal 'FooTest#test_bar', LazyLoader.build_test_id('FooTest', 'test_bar')
    end

    def test_build_test_id_namespaced
      assert_equal 'Foo::Bar#test_baz', LazyLoader.build_test_id('Foo::Bar', 'test_baz')
    end

    # === build_manifest ===

    def test_build_manifest_from_tests
      tests = [
        FakeTest.new('TestA', 'test_foo', '/path/to/test_a.rb'),
        FakeTest.new('TestA', 'test_bar', '/path/to/test_a.rb'),
        FakeTest.new('TestB', 'test_baz', '/path/to/test_b.rb'),
      ]

      manifest = LazyLoader.build_manifest(tests)

      assert_equal 2, manifest.size
      assert_equal '/path/to/test_a.rb', manifest['TestA']
      assert_equal '/path/to/test_b.rb', manifest['TestB']
    end

    def test_build_manifest_skips_nil_class_names
      tests = [
        FakeTest.new(nil, 'test_foo', '/path/to/test.rb'),
        FakeTest.new('TestA', 'test_bar', '/path/to/test_a.rb'),
      ]

      manifest = LazyLoader.build_manifest(tests)

      assert_equal 1, manifest.size
      assert_equal '/path/to/test_a.rb', manifest['TestA']
    end

    def test_build_manifest_skips_tests_without_source_location
      tests = [
        FakeTest.new('TestA', 'test_foo', nil),
        FakeTest.new('TestB', 'test_bar', '/path/to/test_b.rb'),
      ]

      manifest = LazyLoader.build_manifest(tests)

      assert_equal 1, manifest.size
      assert_equal '/path/to/test_b.rb', manifest['TestB']
    end

    def test_build_manifest_warns_on_duplicate_class_names
      tests = [
        FakeTest.new('DuplicateTest', 'test_foo', '/path/to/file1.rb'),
        FakeTest.new('DuplicateTest', 'test_bar', '/path/to/file2.rb'),
      ]

      warning_output = capture_io do
        manifest = LazyLoader.build_manifest(tests)
        # Last one wins
        assert_equal '/path/to/file2.rb', manifest['DuplicateTest']
      end[1] # stderr

      assert_includes warning_output, "WARNING: Duplicate class name 'DuplicateTest'"
      assert_includes warning_output, '/path/to/file1.rb'
      assert_includes warning_output, '/path/to/file2.rb'
    end

    def test_build_manifest_no_warning_for_same_file
      # Same class from same file should not warn
      tests = [
        FakeTest.new('TestA', 'test_foo', '/path/to/test_a.rb'),
        FakeTest.new('TestA', 'test_bar', '/path/to/test_a.rb'),
      ]

      warning_output = capture_io do
        LazyLoader.build_manifest(tests)
      end[1] # stderr

      refute_includes warning_output, 'WARNING'
    end

    # === set_manifest ===

    def test_set_manifest
      manifest = { 'TestA' => '/path/to/test_a.rb' }
      @loader.set_manifest(manifest)

      # Verify by trying to load a class (will fail but shows manifest is set)
      error = assert_raises(LazyLoadError) { @loader.load_class('NonExistent') }
      assert_match(/No manifest entry/, error.message)
    end

    # === store_manifest and fetch_manifest ===

    def test_store_and_fetch_manifest
      redis = MockRedis.new
      manifest = { 'TestA' => '/path/to/test_a.rb', 'TestB' => '/path/to/test_b.rb' }

      @loader.store_manifest(redis, 'test-key', manifest, ttl: 3600)

      # Create a new loader to fetch
      loader2 = LazyLoader.new
      fetched = loader2.fetch_manifest(redis, 'test-key')

      assert_equal manifest, fetched
    end

    def test_store_manifest_skips_empty_manifest
      redis = MockRedis.new
      @loader.store_manifest(redis, 'test-key', {}, ttl: 3600)

      refute redis.key_exists?('test-key')
    end

    def test_fetch_manifest_returns_cached_manifest
      redis = MockRedis.new
      manifest = { 'TestA' => '/path/to/test_a.rb' }
      @loader.set_manifest(manifest)

      # Should return cached manifest without hitting Redis
      fetched = @loader.fetch_manifest(redis, 'nonexistent-key')
      assert_equal manifest, fetched
    end

    def test_fetch_manifest_retries_on_empty
      redis = MockRedis.new
      redis.set_empty_results(2) # Return empty twice, then return data

      manifest = { 'TestA' => '/path/to/test_a.rb' }
      redis.hset('test-key', manifest)

      fetched = @loader.fetch_manifest(redis, 'test-key', retries: 3, retry_delay: 0.01)
      assert_equal manifest, fetched
      assert_equal 3, redis.hgetall_call_count
    end

    def test_fetch_manifest_raises_after_retries_exhausted
      redis = MockRedis.new
      # Always return empty

      error = assert_raises(LazyLoadError) do
        @loader.fetch_manifest(redis, 'nonexistent-key', retries: 2, retry_delay: 0.01)
      end

      assert_match(/Failed to fetch manifest/, error.message)
      assert_match(/2 attempts/, error.message)
    end

    # === load_class ===

    def test_load_class_raises_for_missing_manifest_entry
      @loader.set_manifest({})

      error = assert_raises(LazyLoadError) { @loader.load_class('NonExistent') }
      assert_match(/No manifest entry for NonExistent/, error.message)
    end

    def test_load_class_tracks_loaded_files
      # Use a real file that exists
      test_file = create_temp_test_file('LoadClassTest', 'test_example')
      @loader.set_manifest({ 'LoadClassTest' => test_file })

      @loader.load_class('LoadClassTest')

      assert_includes @loader.loaded_files, test_file
      assert_equal 1, @loader.files_loaded_count
    ensure
      Object.send(:remove_const, :LoadClassTest) if defined?(LoadClassTest)
    end

    def test_load_class_only_loads_file_once
      test_file = create_temp_test_file('LoadOnceTest', 'test_example')
      @loader.set_manifest({ 'LoadOnceTest' => test_file })

      @loader.load_class('LoadOnceTest')
      @loader.load_class('LoadOnceTest')

      assert_equal 1, @loader.files_loaded_count
    ensure
      Object.send(:remove_const, :LoadOnceTest) if defined?(LoadOnceTest)
    end

    # === find_class ===

    def test_find_class_simple
      klass = @loader.find_class('String')
      assert_equal String, klass
    end

    def test_find_class_namespaced
      klass = @loader.find_class('CI::Queue::LazyLoader')
      assert_equal CI::Queue::LazyLoader, klass
    end

    def test_find_class_raises_helpful_error_for_missing_class
      @loader.set_manifest({ 'NonExistent' => '/fake/path.rb' })

      error = assert_raises(LazyLoadError) { @loader.find_class('NonExistent') }
      assert_match(/Class NonExistent not found/, error.message)
      assert_match(%r{/fake/path.rb}, error.message)
    end

    # === load_test ===

    def test_load_test_loads_class_and_instantiates
      test_file = create_temp_test_file('LoadTestTest', 'test_example')
      @loader.set_manifest({ 'LoadTestTest' => test_file })

      instance = @loader.load_test('LoadTestTest', 'test_example')

      assert_instance_of LoadTestTest, instance
      assert_equal 'test_example', instance.name
    ensure
      Object.send(:remove_const, :LoadTestTest) if defined?(LoadTestTest)
    end

    # === instantiate_test ===

    def test_instantiate_test
      instance = @loader.instantiate_test('Minitest::Test', 'test_example')
      assert_instance_of Minitest::Test, instance
    end

    private

    def create_temp_test_file(class_name, method_name)
      file = Tempfile.new(['test_', '.rb'])
      file.write(<<~RUBY)
        class #{class_name} < Minitest::Test
          def #{method_name}
            assert true
          end
        end
      RUBY
      file.close
      file.path
    end

    # Fake test object for build_manifest tests
    class FakeTest
      attr_reader :name

      def initialize(class_name, method_name, source_location)
        @class_name = class_name
        @method_name = method_name
        @source_location = source_location
        @name = method_name
      end

      def class
        FakeClass.new(@class_name)
      end

      def method(_name)
        FakeMethod.new(@source_location)
      end

      class FakeClass
        def initialize(name)
          @name = name
        end

        def name
          @name
        end
      end

      class FakeMethod
        def initialize(source_location)
          @source_location = source_location
        end

        def source_location
          @source_location ? [@source_location, 1] : nil
        end
      end
    end

    # Mock Redis for testing
    class MockRedis
      def initialize
        @data = {}
        @hgetall_call_count = 0
        @empty_results_remaining = 0
      end

      attr_reader :hgetall_call_count

      def set_empty_results(count)
        @empty_results_remaining = count
      end

      def hset(key, hash)
        @data[key] = hash.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def hgetall(key)
        @hgetall_call_count += 1
        if @empty_results_remaining > 0
          @empty_results_remaining -= 1
          return {}
        end
        @data[key] || {}
      end

      def expire(key, ttl)
        # no-op for tests
      end

      def key_exists?(key)
        @data.key?(key)
      end
    end
  end
end
