# frozen_string_literal: true
RSpec.describe "requeue circuit breaker" do
  6.times do |index|
    it "completes example #{index}" do
      raise "corrupted worker state" if ENV['CORRUPTED_WORKER'] == '1'

      expect(true).to be(true)
    end
  end
end
