# frozen_string_literal: true
require 'test_helper'

class TimeoutTest < Minitest::Test
  def test_timeout
    assert true
    sleep 10
  end
end
