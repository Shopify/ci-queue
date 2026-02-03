# frozen_string_literal: true

require 'json'
require 'set'

module CI
  module Queue
    class LazyLoadError < StandardError; end

    # LazyLoader handles on-demand loading of test files based on a manifest
    # that maps class names to their source file paths.
    #
    # The manifest is a Hash mapping class names (e.g., "MyModule::MyTest") to
    # absolute file paths where those classes are defined.
    #
    # Test IDs follow the format "ClassName#method_name" (e.g., "MyTest#test_foo").
    class LazyLoader
      attr_reader :loaded_files

      def initialize
        @loaded_files = Set.new
        @manifest = {}
      end

      # Build manifest from loaded tests
      # Returns a hash mapping class_name -> file_path
      # Handles both Minitest::Queue::SingleExample and regular test objects
      def self.build_manifest(tests)
        manifest = {}
        tests.each do |test|
          # SingleExample has `runnable` (the class) and `method_name`
          # Regular test objects have `class` and `name`
          if test.respond_to?(:runnable)
            # Minitest::Queue::SingleExample
            class_name = test.runnable.name
            source_location = test.source_location&.first
          else
            # Regular test object
            class_name = test.class.name
            method_name = test.respond_to?(:method_name) ? test.method_name : test.name
            source_location = test.method(method_name).source_location&.first rescue nil
          end

          next if class_name.nil? || source_location.nil?

          # Warn about duplicate class names - only one file path will be used
          if manifest.key?(class_name) && manifest[class_name] != source_location
            warn "[ci-queue] WARNING: Duplicate class name '#{class_name}' found in multiple files:\n" \
                 "  - #{manifest[class_name]}\n" \
                 "  - #{source_location}\n" \
                 "Only one will be used for lazy loading. Rename one class to avoid test failures."
          end

          manifest[class_name] = source_location
        end
        manifest
      end

      # Store manifest in Redis
      # key: Redis key to store the manifest
      def store_manifest(redis, key, manifest, ttl:)
        return if manifest.empty?

        redis.hset(key, manifest)
        redis.expire(key, ttl)
      end

      # Fetch manifest from Redis with retry logic
      # key: Redis key where manifest is stored
      # retries: number of retries if manifest is empty
      def fetch_manifest(redis, key, retries: 3, retry_delay: 0.5)
        return @manifest unless @manifest.empty?

        retries.times do |attempt|
          @manifest = redis.hgetall(key)
          break unless @manifest.empty?

          sleep(retry_delay * (attempt + 1)) if attempt < retries - 1
        end

        if @manifest.empty?
          raise LazyLoadError, "Failed to fetch manifest from Redis after #{retries} attempts. " \
                               "The leader may not have finished populating the queue."
        end

        @manifest
      end

      # Set manifest directly (e.g., from leader)
      def set_manifest(manifest)
        @manifest = manifest
      end

      # Load test class if not already loaded
      # Returns the test runnable instance
      def load_test(class_name, method_name)
        load_class(class_name)
        instantiate_test(class_name, method_name)
      end

      # Load a class from the manifest
      def load_class(class_name)
        file_path = @manifest[class_name]
        raise LazyLoadError, "No manifest entry for #{class_name}" unless file_path

        # Use `load` instead of `require` - classes may be partially defined
        # (constant exists but methods missing due to autoloader/parent class).
        # Ruby's require checks $LOADED_FEATURES and may skip re-execution,
        # whereas load always executes the file.
        # We track loaded files ourselves to prevent duplicate loading.
        unless @loaded_files.include?(file_path)
          load(file_path)
          @loaded_files.add(file_path)
        end
      end

      # Find a class by name using const_get
      # Raises LazyLoadError with helpful message if class not found
      def find_class(class_name)
        class_name.split('::').reduce(Object) do |ns, const|
          ns.const_get(const, false)
        end
      rescue NameError => e
        file_path = @manifest[class_name]
        raise LazyLoadError, "Class #{class_name} not found after loading #{file_path}. " \
                             "The file may not define the expected class. Original error: #{e.message}"
      end

      # Instantiate a test runnable
      def instantiate_test(class_name, method_name)
        klass = find_class(class_name)
        klass.new(method_name)
      end

      # Parse a test identifier into class_name and method_name
      def self.parse_test_id(test_id)
        # Test IDs are in format "ClassName#method_name" or "Module::ClassName#method_name"
        class_name, method_name = test_id.split('#', 2)
        [class_name, method_name]
      end

      # Build a test identifier from class_name and method_name
      def self.build_test_id(class_name, method_name)
        "#{class_name}##{method_name}"
      end

      def files_loaded_count
        @loaded_files.size
      end
    end
  end
end
