require 'ci/queue/static'

module CI
  module Queue
    class File < Static
      def initialize(path, **args)
        super(::File.readlines(path).map(&:strip).reject(&:empty?), **args)
      end
    end
  end
end
