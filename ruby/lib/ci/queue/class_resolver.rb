# frozen_string_literal: true

module CI
  module Queue
    module ClassResolver
      def self.resolve(class_name, file_path: nil, loader: nil)
        klass = try_direct_lookup(class_name)
        return klass if klass

        if file_path && loader
          loader.load_file(file_path)
          klass = try_direct_lookup(class_name)
          return klass if klass
        end

        raise ClassNotFoundError, "Unable to resolve class #{class_name}"
      end

      def self.try_direct_lookup(class_name)
        parts = class_name.sub(/\A::/, '').split('::')
        current = Object

        parts.each do |name|
          return nil unless current.const_defined?(name, false)

          current = current.const_get(name, false)
        end

        return nil unless current.is_a?(Class)

        current
      rescue NameError
        nil
      end
      private_class_method :try_direct_lookup
    end
  end
end
