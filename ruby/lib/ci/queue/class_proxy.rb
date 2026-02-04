# frozen_string_literal: true

module CI
  module Queue
    # A proxy object that acts like a Class but serializes as a string for DRb compatibility.
    # This allows Class objects to be sent over DRb in lazy loading scenarios where the
    # actual Class object can't be marshaled.
    class ClassProxy < BasicObject
      def initialize(klass_or_name)
        @class_name = klass_or_name.is_a?(::String) ? klass_or_name : klass_or_name.to_s
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

      # Custom marshaling: serialize as class name string
      def marshal_dump
        @class_name
      end

      def marshal_load(class_name)
        @class_name = class_name
        @klass = nil
      end

      private

      def target_class
        @klass ||= @class_name.split('::').reduce(::Object) { |mod, const| mod.const_get(const) }
      end
    end
  end
end
