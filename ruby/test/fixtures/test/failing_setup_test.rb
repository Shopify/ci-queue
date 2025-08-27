# frozen_string_literal: true
require 'test_helper'

class FailingTest < Minitest::Test
  def setup
    raise "Setup failed"
  end

  100.times do |i|
    define_method("test_failing_#{i}") do
      assert true
    end
  end
end
