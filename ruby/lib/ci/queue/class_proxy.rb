# frozen_string_literal: true

module CI
  module Queue
    # A proxy object that acts like a Class but serializes as a string for DRb compatibility.
    # This allows Class objects to be sent over DRb in lazy loading scenarios where the
    # actual Class object can't be marshaled.
    class ClassProxy < BasicObject
      # Track loaded files across all ClassProxy instances to prevent duplicate loads
      @@loaded_files = ::Set.new
      @@load_mutex = ::Mutex.new

      def initialize(klass_or_name, file_path: nil)
        @class_name = klass_or_name.is_a?(::String) ? klass_or_name : klass_or_name.to_s
        @file_path = file_path
        @klass = nil
      end

      # Delegate all method calls to the actual class
      def method_missing(method, *args, &block)
        target_class.public_send(method, *args, &block)
      end

      def respond_to_missing?(method, include_private = false)
        target_class.respond_to?(method, include_private)
      end

      # Make it look like a Class for is_a? checks
      def is_a?(klass)
        klass == ::Class || target_class.is_a?(klass)
      end
      alias_method :kind_of?, :is_a?

      # Equality comparison - compare to the actual class
      def ==(other)
        if other.instance_of?(::CI::Queue::ClassProxy)
          @class_name == other.instance_variable_get(:@class_name)
        else
          target_class == other
        end
      end
      alias_method :eql?, :==

      def hash
        target_class.hash
      end

      # Return the class name for string operations
      def to_s
        @class_name
      end

      def inspect
        target_class.inspect
      end

      # Custom marshaling: serialize as class name string and file path
      def marshal_dump
        { class_name: @class_name, file_path: @file_path }
      end

      def marshal_load(data)
        @class_name = data[:class_name]
        @file_path = data[:file_path]
        @klass = nil
      end

      private

      def target_class
        return @klass if @klass

        # Try to resolve the constant
        @klass = resolve_constant(@class_name)
      rescue ::NameError => e
        # If constant not found and we have a file path, try loading the file
        if @file_path
          load_test_file(@file_path)
          # Retry constant lookup after loading
          begin
            @klass = resolve_constant(@class_name)
          rescue ::NameError => retry_error
            # File loaded but class still not found - provide helpful error
            ::Kernel.raise ::NameError,
              "Class #{@class_name} not found after loading #{@file_path}. " \
              "The file may not define the expected class. Original error: #{retry_error.message}"
          end
        else
          ::Kernel.raise e
        end
      end

      def resolve_constant(class_name)
        class_name.split('::').reduce(::Object) { |mod, const| mod.const_get(const) }
      end

      def load_test_file(file_path)
        # Validate file path for security
        unless file_path.end_with?('.rb')
          ::Kernel.raise ::ArgumentError, "Invalid test file path (must end with .rb): #{file_path}"
        end

        # Check if file exists
        unless ::File.exist?(file_path)
          ::Kernel.raise ::LoadError, "Test file not found: #{file_path}"
        end

        # Thread-safe file loading with deduplication
        return if @@loaded_files.include?(file_path)

        @@load_mutex.synchronize do
          # Double-check inside mutex to prevent race condition
          return if @@loaded_files.include?(file_path)

          ::Kernel.load(file_path)
          @@loaded_files.add(file_path)
        end
      end
    end
  end
end
