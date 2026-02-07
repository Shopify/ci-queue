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
        @expanded_file_path = ::File.expand_path(file_path) if file_path
        @klass = nil
      end

      # Delegate all method calls to the actual class.
      # Uses ... forwarding (Ruby 2.7+) to properly forward keyword arguments.
      def method_missing(method, ...)
        target_class.public_send(method, ...)
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
        @expanded_file_path = ::File.expand_path(@file_path) if @file_path
        @klass = nil
      end

      private

      def target_class
        return @klass if @klass

        # Step 1: Try to resolve the constant without loading any files.
        resolved = begin
          resolve_constant(@class_name)
        rescue ::NameError
          nil
        end

        # Step 2: If resolved, handle Module-vs-Class (needs_class_resolution).
        if resolved
          if resolved.is_a?(::Module) && !resolved.is_a?(::Class) && @file_path
            resolved = find_class_from_file
          end
        end

        # Step 3: For short class names (no ::), verify the resolved class
        # actually comes from the expected file. Without this, a top-level
        # "OrderTest" (app class) could shadow a test class with the same name.
        # Fully-qualified names (e.g., "GraphApi::Admin::ShopTest") don't need
        # this check — resolve_constant walked the full namespace and found
        # the right class.
        # NOTE: Do NOT set @klass until verification passes (P0 fix).
        if resolved && @expanded_file_path && !@class_name.include?('::')
          if !class_from_expected_file?(resolved)
            resolved = nil
          end
        end

        # Step 4: If class is correct, cache and return.
        if resolved
          @klass = resolved
          return @klass
        end

        # Step 5: Class not found or wrong class — load the file and resolve.
        # Try require first (safe, idempotent). If that doesn't surface the class
        # (forked worker where $LOADED_FEATURES is inherited but classes aren't),
        # fall back to Kernel.load which re-executes the file.
        if @file_path
          load_test_file(@file_path)

          resolved = begin
            resolve_constant(@class_name)
          rescue ::NameError
            nil
          end

          # For short names, verify source location after loading.
          if resolved && @expanded_file_path && !@class_name.include?('::') && !class_from_expected_file?(resolved)
            better = find_class_from_file
            resolved = better if better # Keep original if ObjectSpace can't find a better match
          end

          # If require didn't help AND resolve_constant failed (forked worker
          # where class truly doesn't exist), force re-execute with Kernel.load.
          # Do NOT force-load if we have a resolved class — that would re-execute
          # the file and cause "already defined" errors.
          if resolved.nil?
            force_load_test_file(@file_path)

            resolved = begin
              resolve_constant(@class_name)
            rescue ::NameError
              nil
            end
          end

          if resolved
            @klass = resolved
            return @klass
          end

          ::Kernel.raise ::NameError,
            "Class #{@class_name} not found after loading #{@file_path}. " \
            "The file may not define the expected class."
        else
          ::Kernel.raise ::NameError, "uninitialized constant #{@class_name}"
        end
      end

      # Check if a resolved class was defined in the expected file.
      def class_from_expected_file?(klass)
        source = begin
          ::Object.const_source_location(klass.name)&.first
        rescue ::StandardError, ::NotImplementedError
          return true # Can't determine source — assume correct
        end
        return true unless source # No source info — assume correct

        ::File.expand_path(source) == @expanded_file_path
      end

      # Find a class by name that was defined in @file_path.
      # Uses ObjectSpace scan as a last resort when const_get finds the wrong class.
      def find_class_from_file
        short_name = @class_name

        ::ObjectSpace.each_object(::Class) do |klass|
          begin
            klass_name = klass.name
            next unless klass_name
            next unless klass_name == short_name || klass_name.end_with?("::#{short_name}")

            source = ::Object.const_source_location(klass_name)&.first
            next unless source

            return klass if ::File.expand_path(source) == @expanded_file_path
          rescue ::StandardError, ::NotImplementedError
            next
          end
        end

        nil
      end

      def resolve_constant(class_name)
        class_name.split('::').reduce(::Object) { |mod, const| mod.const_get(const) }
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
        unless file_path.end_with?('.rb')
          ::Kernel.raise ::ArgumentError, "Invalid test file path (must end with .rb): #{file_path}"
        end

        expanded = @expanded_file_path || ::File.expand_path(file_path)

        # Dedup: skip if already loaded in this process.
        return if ::CI::Queue::ClassProxy.loaded_files_for_pid[expanded]

        unless ::File.exist?(expanded)
          ::Kernel.raise ::LoadError, "Test file not found: #{file_path}"
        end

        # Try require first (idempotent, safe for non-forked processes).
        # If the file is in $LOADED_FEATURES, require is a no-op.
        # For forked workers where $LOADED_FEATURES is inherited but class
        # definitions aren't, require will be a no-op and the caller (target_class)
        # will call force_load_test_file as a fallback.
        ::Kernel.require(expanded)
        ::CI::Queue::ClassProxy.loaded_files_for_pid[expanded] = true
      end

      # Force re-execute a file with Kernel.load. Used as a fallback when
      # require was a no-op (file in $LOADED_FEATURES from parent) but the
      # class doesn't exist (forked worker without class definitions).
      def force_load_test_file(file_path)
        expanded = @expanded_file_path || ::File.expand_path(file_path)
        ::Kernel.load(expanded)
        ::CI::Queue::ClassProxy.loaded_files_for_pid[expanded] = true
      end
    end
  end
end
