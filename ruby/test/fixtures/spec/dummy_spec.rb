# frozen_string_literal: true
RSpec.describe Object do
  it "works" do
    expect(1 + 1).to be == 2
  end

  it "doesn't work on first try" do
    if defined?($failing_test_called) && $failing_test_called || ENV['RETRIED'] == "1"
      expect(1 + 1).to be == 2
    else
      $failing_test_called = true
      expect(1 + 1).to be == 42
    end
  end

  describe 'some subclass' do

    it "should be ran as well" do
      expect(1 + 1).to be == 2
    end

  end
end
