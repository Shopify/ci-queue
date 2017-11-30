RSpec.describe Object do
  it "works" do
    expect(1 + 1).to be == 2
  end

  it "doesn't work" do
    expect(1 + 1).to be == 42
  end

  describe 'some sublclass' do

    it "should be ran as well" do
      expect(1 + 1).to be == 2
    end

  end
end
