# frozen_string_literal: true
require 'ci/queue/static'

module CI
  module Queue
    class Grind < Static
      class << self
        def from_uri(uri, config)
          new(uri.path, config)
        end
      end

      # Grind always eagerly loads test files and populates @index via
      # Static#populate, so poll uses the @index path. Bypass entry_resolver
      # to avoid JSON-formatting overhead on potentially millions of entries.
      def entry_resolver; nil; end
      def entry_resolver=(_); end

      def initialize(path, config)
        io = path == '-' ? STDIN : ::File.open(path)

        tests_to_run = io.each_line.map(&:strip).reject(&:empty?)
        test_grinds = (tests_to_run * config.grind_count).sort

        super(test_grinds, config)
      end
    end
  end
end
