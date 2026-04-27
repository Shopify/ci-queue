# frozen_string_literal: true
require 'test_helper'

module CI
  module QueueTest
    class TestInclusionFilterTest < Minitest::Test
      def setup
        @previous_filter = CI::Queue.test_inclusion_filter
      end

      def teardown
        CI::Queue.test_inclusion_filter = @previous_filter
      end

      def test_include_test_returns_true_when_filter_unset
        CI::Queue.test_inclusion_filter = nil
        assert CI::Queue.include_test?(Class.new, "test_anything")
      end

      def test_include_test_invokes_filter_with_runnable_and_method_name
        runnable = Class.new
        captured = []
        CI::Queue.test_inclusion_filter = ->(r, m) { captured << [r, m]; true }

        assert CI::Queue.include_test?(runnable, "test_foo")
        assert_equal [[runnable, "test_foo"]], captured
      end

      def test_include_test_returns_false_when_filter_returns_false
        CI::Queue.test_inclusion_filter = ->(_, _) { false }
        refute CI::Queue.include_test?(Class.new, "test_anything")
      end

      def test_include_test_propagates_truthy_falsey_returns
        CI::Queue.test_inclusion_filter = ->(_, _) { nil }
        refute CI::Queue.include_test?(Class.new, "test_anything")

        CI::Queue.test_inclusion_filter = ->(_, _) { :keep }
        assert CI::Queue.include_test?(Class.new, "test_anything")
      end
    end
  end
end
