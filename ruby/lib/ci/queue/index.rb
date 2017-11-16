module CI
  module Queue
    class Index
      def initialize(objects, &indexer)
        @index = objects.map { |o| [indexer.call(o), o] }.to_h
        @indexer = indexer
      end

      def fetch(key)
        @index.fetch(key)
      end

      def key(value)
        key = @indexer.call(value)
        raise KeyError, "value not found: #{value.inspect}" unless @index.key?(key)
        key
      end
    end
  end
end
