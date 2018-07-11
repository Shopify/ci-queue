RSpec.world.wants_to_quit = !!ENV['EARLY_EXIT']

RSpec.describe Object do
  it "should be executed" do
    expect(1 + 1).to be == 4
  end
end
