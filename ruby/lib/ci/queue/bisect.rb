# frozen_string_literal: true
module CI
  module Queue
    class Bisect
      def initialize(path, config)
        @tests = ::File.readlines(path).map(&:strip).reject(&:empty?).take_while { |t| t != config.failing_test }
        @config = config
      end

      def size
        @tests.size
      end

      def populate(all_tests, random: nil)
        @all_tests = all_tests
      end

      def to_a
        @tests + [config.failing_test]
      end

      def suspects_left
        @tests.size
      end

      def failing_test
        Static.new([config.failing_test], config).populate(@all_tests)
      end

      def candidates
        Static.new(first_half + [config.failing_test], config).populate(@all_tests)
      end

      def failed!
        @tests = first_half
      end

      def succeeded!
        @tests = second_half
      end

      private

      attr_reader :config

      def slices
        @tests.each_slice((@tests.size / 2.0).ceil).to_a
      end

      def first_half
        slices.first
      end

      def second_half
        slices.last
      end
    end
  end
end
