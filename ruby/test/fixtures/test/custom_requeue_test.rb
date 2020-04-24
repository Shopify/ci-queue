# frozen_string_literal: true
require 'test_helper'

CI::Queue.requeueable = -> (result) do
  !result.failures.any? do |failure|
    failure.error.is_a?(TypeError)
  end
end

class ATest < Minitest::Test
  def test_requeue_allowed
    1 + '1' # TypeError
  end

  def test_requeue_disallowed
    1.bar # NoMethodError
  end
end
