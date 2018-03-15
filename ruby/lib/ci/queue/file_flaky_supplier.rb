require 'json'

module CI
  module Queue
    class FileFlakySupplier
      FileParseError = Class.new(StandardError)

      def initialize(filepath)
        @test_list = ::File.readlines(filepath)
        @test_list.map!(&:chomp)
      end

      def include?(runnable_id)
        ::File.write('runnable_debuggoing.txt', "#{runnable_id} is looked for in #{@test_list}\n", mode: 'a')
        @test_list.include?(runnable_id)
      end
    end
  end
end
