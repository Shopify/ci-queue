# frozen_string_literal: true
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
        io = path == '-' ? STDIN : ::File.open(path)
        super(io.each_line.map(&:strip).reject(&:empty?), *args)
      end
    end
  end
end
