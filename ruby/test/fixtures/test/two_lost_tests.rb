# frozen_string_literal: true
require 'test_helper'

CI::Queue::Redis.max_sleep_time = 0.05

class TwoLostTests < Minitest::Test

  def test_alpha
    sleep 3
  end

  def test_beta
    sleep 3
  end

end
