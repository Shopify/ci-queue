# frozen_string_literal: true
require 'test_helper'

class PassingTest < Minitest::Test
  100.times do |i|
    define_method("test_passing_#{i}") do
      assert true
    end
  end
end
