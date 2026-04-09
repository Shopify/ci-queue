# frozen_string_literal: true
require 'test_helper'

CI::Queue::Redis.max_sleep_time = 0.05

# Fixture for test_heartbeat_cap_resets_between_tests.
#
# test_alpha fires the heartbeat cap (sleep 2 > cap 1s) but finishes before going stale
# (sleep 2 < cap 1 + heartbeat 2 = 3s). This sets capped=true in the heartbeat thread.
# After test_alpha, :reset is sent and capped should be false.
#
# test_beta sleeps in the range (heartbeat=2, heartbeat+cap=3):
#   - Without reset: no ticks, stale at t_B + 2s, finishes at t_B + 2.5s → STOLEN
#   - With reset: ticks until cap at t_B + 1s, stale at t_B + 3s, finishes at t_B + 2.5s → NOT stolen
class ConsecutiveCappedTests < Minitest::Test
  def test_alpha
    sleep 2
  end

  def test_beta
    sleep 2.5
  end
end
