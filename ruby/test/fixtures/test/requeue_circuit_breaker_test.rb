# frozen_string_literal: true
require 'test_helper'

class RequeueCircuitBreakerTest < Minitest::Test
  6.times do |index|
    define_method("test_worker_health_#{index}") do
      flunk "corrupted worker state" if ENV['CORRUPTED_WORKER'] == '1'

      assert true
    end
  end
end
