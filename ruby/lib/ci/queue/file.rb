require 'ci/queue/static'

module CI
  module Queue
    class File < Static
      class << self
        def from_uri(uri)
          new(uri.path, parse_query(uri.query))
        end
      end

      def initialize(path, **args)
        super(::File.readlines(path).map(&:strip).reject(&:empty?), **args)
      end
    end
  end
end
