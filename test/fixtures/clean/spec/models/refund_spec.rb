RSpec.describe Refund do
  describe "#valid?" do
    it "rejects a blank amount" do
      expect(Refund.new(amount: nil)).not_to be_valid
    end

    it "rejects a negative amount" do
      expect(described_class.new(amount: -1)).not_to be_valid
    end

    it "rejects a foreign currency" do
      expect(Refund.new(amount: 1, currency: "XX")).not_to be_valid
    end
  end
end
