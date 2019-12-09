# frozen_string_literal: true
require 'test_helper'

class FlakyTest < Minitest::Test
  def test_dummy
    assert true
  end

  def test_flaky
    assert_equal '1', ENV['FLAKY_TEST_PASS']
  end
end
