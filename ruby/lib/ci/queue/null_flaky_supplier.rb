module CI
  module Queue
    module NullFlakySupplier
      def self.include?(_)
        false
      end
    end
  end
end
