require 'ci/queue/static'

module CI
  module Queue
    class File < Static
      class << self
        def from_uri(uri, config)
          new(uri.path, config)
        end
      end

      def initialize(path, *args)
        super(::File.readlines(path).map(&:strip).reject(&:empty?), *args)
      end
    end
  end
end
