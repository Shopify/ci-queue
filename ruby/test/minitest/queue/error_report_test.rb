# frozen_string_literal: true
require 'test_helper'

module Minitest
  module Queue
    class ErrorReportTest < Minitest::Test
      def test_default_coder
        assert defined? Minitest::Queue::ErrorReport::SnappyPack
        assert_equal Minitest::Queue::ErrorReport::SnappyPack, Minitest::Queue::ErrorReport.coder
      end

      def test_snappypack_coder
        original_hash = {foo: 'bar'}
        round_trip = Minitest::Queue::ErrorReport.coder.load(Minitest::Queue::ErrorReport.coder.dump(original_hash))
        assert_equal original_hash, round_trip
      end
    end
  end
end
