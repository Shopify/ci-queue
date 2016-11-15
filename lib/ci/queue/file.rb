require 'ci/queue/static'

module CI
  module Queue
    class File < Static
      def initialize(path)
        super(::File.readlines(path).map(&:strip).reject(&:empty?))
      end
    end
  end
end
