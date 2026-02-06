# frozen_string_literal: true

module CI
  module Queue
    # A proxy object that acts like a Class but serializes as a string for DRb compatibility.
    # This allows Class objects to be sent over DRb in lazy loading scenarios where the
    # actual Class object can't be marshaled.
    class ClassProxy < BasicObject
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

        # Always load the test file first if we have a file_path.
        # This is necessary because the constant may already exist in the process
        # (e.g., a top-level CheckoutTest loaded during boot) but without the test
        # methods (which are only defined when the test FILE is loaded). Loading
        # the file ensures test methods exist before we resolve the constant.
        load_test_file(@file_path) if @file_path

        @klass = resolve_constant(@class_name)
        @klass = resolve_class_from_file if needs_class_resolution?
        @klass
      rescue ::NameError => e
        if @file_path
          # File was already loaded above but constant still not found
          ::Kernel.raise ::NameError,
            "Class #{@class_name} not found after loading #{@file_path}. " \
            "The file may not define the expected class. Original error: #{e.message}"
        else
          ::Kernel.raise e
        end
      end

      def needs_class_resolution?
        @klass.is_a?(::Module) && !@klass.is_a?(::Class) && @file_path
      end

      def resolve_constant(class_name)
        class_name.split('::').reduce(::Object) { |mod, const| mod.const_get(const) }
      end

      # NOTE: This method uses ObjectSpace.each_object(Class) which can be expensive
      # in large processes. It's only called when a constant resolves to a Module
      # instead of a Class (i.e. namespaced test classes where the short name matches
      # a module). Consider fixing the manifest to use fully-qualified class names
      # to avoid this path.
      def resolve_class_from_file
        file_path = ::File.expand_path(@file_path)
        short_name = @class_name

        ::ObjectSpace.each_object(::Class) do |klass|
          # ObjectSpace contains classes from the entire process — gems, engines, etc.
          # Some override .name with non-standard signatures or return values, and
          # const_source_location can raise on invalid constant paths. Rescue broadly
          # since we're just scanning and can safely skip any problematic class.
          begin
            klass_name = klass.name
            next unless klass_name
            next unless klass_name == short_name || klass_name.end_with?("::#{short_name}")

            source = ::Object.const_source_location(klass_name)&.first
            next unless source

            return klass if ::File.expand_path(source) == file_path
          rescue ::StandardError, ::NotImplementedError
            next
          end
        end

        ::Kernel.raise ::NameError,
          "Expected class #{@class_name} in #{@file_path}, but only a module was found"
      end

      # Per-process tracking of loaded files. Uses a class-level hash keyed by
      # PID to automatically reset after fork (child gets parent's hash but
      # checks PID mismatch and rebuilds).
      def self.loaded_files_for_pid
        current_pid = ::Process.pid
        if @loaded_files_pid != current_pid
          @loaded_files_pid = current_pid
          @loaded_files = {}
        end
        @loaded_files ||= {}
      end

      def load_test_file(file_path)
        # Validate file path for security
        unless file_path.end_with?('.rb')
          ::Kernel.raise ::ArgumentError, "Invalid test file path (must end with .rb): #{file_path}"
        end

        expanded = ::File.expand_path(file_path)

        # Dedup: skip if already loaded in this process.
        # target_class calls load_test_file for every ClassProxy instance,
        # so multiple tests from the same file would re-execute it without this check.
        return if ::CI::Queue::ClassProxy.loaded_files_for_pid[expanded]

        unless ::File.exist?(expanded)
          ::Kernel.raise ::LoadError, "Test file not found: #{file_path}"
        end

        # Use load (not require) for fork safety. After fork, child processes
        # inherit $LOADED_FEATURES but not class definitions from files loaded
        # post-fork in the parent. load always re-executes.
        ::Kernel.load(expanded)
        ::CI::Queue::ClassProxy.loaded_files_for_pid[expanded] = true
      end
    end
  end
end
