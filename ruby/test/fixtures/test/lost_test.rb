# frozen_string_literal: true
require 'test_helper'

CI::Queue::Redis.max_sleep_time = 0.05

class LostTest < Minitest::Test

  def test_foo
    sleep 3
  end
end
