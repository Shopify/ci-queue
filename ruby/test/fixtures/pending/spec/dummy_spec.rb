# frozen_string_literal: true
RSpec.describe Object do
  it "works" do
    expect(1 + 1).to be == 2
  end

  xit "pending 'xit' example should be ignored" do
    expect(true).to eq false
  end
end
