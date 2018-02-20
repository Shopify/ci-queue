require 'json'

module CI
  module Queue
    class FileFlakySupplier
      FileParseError = Class.new(StandardError)

      def initialize(filepath)
        @test_list = JSON.parse(::File.read(filepath))
        unless @test_list.is_a?(Array)
          raise FileParseError, 'File must contain a JSON encoded array'
        end
      end

      def include?(runnable_id)
        @test_list.include?(runnable_id)
      end
    end
  end
end
