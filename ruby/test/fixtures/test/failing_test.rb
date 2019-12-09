# frozen_string_literal: true
require 'test_helper'

class FailingTest < Minitest::Test
  100.times do |i|
    define_method("test_failing_#{i}") do
      assert false
    end
  end
end
