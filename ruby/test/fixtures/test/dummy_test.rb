# frozen_string_literal: true
require 'test_helper'

class ATest < Minitest::Test

  1000.times do |i|
    define_method("test_dummy_#{i}") do
      assert true
    end
  end
end
