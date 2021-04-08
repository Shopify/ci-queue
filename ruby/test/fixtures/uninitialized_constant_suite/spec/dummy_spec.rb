# frozen_string_literal: true
RSpec.describe NonExistingObject do
  it "won't run" do
    expect(1 + 1).to be == 2
  end
end
