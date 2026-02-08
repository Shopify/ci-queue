# frozen_string_literal: true
require 'test_helper'

# Simulates frameworks that dynamically generate test methods in runnable_methods
# (e.g., Shopify's Verdict FLAGS). The generated methods only exist after
# runnable_methods is called, NOT at class definition time.
class DynamicTest < Minitest::Test
  VARIANTS = %w[alpha beta gamma].freeze

  # Static method - always exists
  def test_static
    assert true
  end

  singleton_class.prepend(Module.new do
    def runnable_methods
      # Generate variant methods on first call (idempotent)
      VARIANTS.each do |variant|
        method_name = "test_dynamic_VARIANT:#{variant}"
        unless instance_methods(false).include?(method_name.to_sym)
          define_method(method_name) do
            assert true
          end
        end
      end
      super
    end
  end)
end
