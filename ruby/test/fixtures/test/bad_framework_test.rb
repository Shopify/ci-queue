# frozen_string_literal: true
require "test_helper"

class Minitest::Queue::SingleExample
  def run
    raise StandardError, "Some error in the test framework"
  end
end

class BadFrameworkTest < Minitest::Test
  def test_foo
    assert false
  end
end
