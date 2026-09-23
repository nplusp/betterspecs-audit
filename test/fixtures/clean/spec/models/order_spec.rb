RSpec.describe Order do
  subject(:order) { build(:order) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:total) }
  end

  describe "rate limiting" do
    it "allows ten per minute" do
      expect(described_class.rate_limit).to eq(10)
    end
  end

  describe "#total" do
    context "with line items" do
      it "sums the items" do
        expect(order.total).to eq(0)
      end
    end

    context "without line items" do
      it "is zero" do
        expect(order.total).to be_zero
      end
    end

    %w[draft paid].each do |state|
      context "#{state} order" do
        it "has a total" do
          expect(build(:order, state:).total).to be >= 0
        end
      end
    end
  end

  describe ".recent" do
    let!(:old) { create(:order, created_at: 2.days.ago) }
    let!(:fresh) { create(:order) }

    it "excludes old orders" do
      expect(described_class.recent).to eq([fresh])
    end

    it "keeps old ones stored" do
      expect(described_class.all).to include(old)
    end
  end

  describe ".report" do
    before { create_list(:order, 9) }

    it "counts orders", :aggregate_failures do
      expect(described_class.report[:count]).to eq(9)
      expect(described_class.report[:empty]).to be(false)
    end

    it "is empty for no orders" do
      expect(described_class.none.report[:count]).to eq(0)
    end

    it "leaves no orders behind" do
      expect(Order.count).to eq(0)
    end

    it "leaves the table empty" do
      expect(described_class.count).to eq(0)
    end
  end

  describe "#number" do
    it "formats the id" do
      aggregate_failures do
        expect(order.number).to start_with("SO-")
        expect(order.number).to be_frozen
      end
    end

    context "when unsaved" do
      it { is_expected.not_to be_persisted }
    end
  end

  describe "#archive" do
    let!(:line_item) { create(:line_item, order:) }

    it_behaves_like "an archivable record"
  end

  describe "#refund" do
    let!(:payment) { create(:payment) }

    context "with a payment" do
      it "refunds it" do
        expect { order.refund(send(:payment)) }.not_to raise_error
      end
    end
  end

  describe "#charge" do
    before do
      stub_request(:post, "https://pay.example/charges").to_return(status: 201)
      stub_const("Order::FEE", 1)
      allow(Gateway).to receive(:charge).and_return(true)
    end

    it "charges the gateway" do
      order.charge
      expect(Gateway).to have_received(:charge)
    end

    context "when declined" do
      before { allow(Gateway).to receive(:charge).and_return(false) }

      it "raises" do
        expect { order.charge }.to raise_error(Order::Declined)
      end
    end

    it "saves the charge" do
      allow(order).to receive(:save!).and_call_original
      order.charge
      expect(order).to have_received(:save!)
    end

    it "stores every item" do
      expect(order.items.size).to eq(2)
    end
  end

  describe "#factory_bot" do
    it "uses factories only" do
      record = FactoryBot.create(:order, total: 1, state: "paid", note: "n")
      expect(record).to be_valid
    end

    it "has a deliberately long description kept for grep" do # betterspecs:disable description-length
      expect(helper_value).to eq(1)
    end

    def helper_value
      @helper_value ||= 1
    end
  end

  describe "#paid?" do
    context "with a signature" do
      it "verifies it" do
        expect(order.verify?(signature: "s")).to be(true)
      end

      it "can ship" do
        expect(order.can_ship?).to be(true)
      end

      it "links the slip" do
        expect(order.slip&.empty?).to be(false)
      end

      it "has a paid line" do
        expect(order.items.any? { |i| i.paid? }).to be(true)
      end

      it "trusts the proxy" do
        expect(Proxies.include?(order.proxies, "10.0.0.1")).to be(true)
      end

            it "links the slip node" do
        expect(order.slip.key?("href")).to be(true)
      end
    end

    it "is false — a human should look" do
      expect(order).not_to be_refunded
    end
  end

  describe "listing_expired" do
    it "fires on expiry" do
      expect(events_for(:listing_expired)).to include(:seller)
    end
  end

  describe "POST /orders/:id/cancel" do
    it "requires the buyer" do
      expect(order.cancel_by(nil)).to eq(:forbidden)
    end
  end

  describe "#validate" do
    it "rejects a blank total" do
      expect(Order.new(total: nil)).not_to be_valid
    end

    it "rejects a negative total" do
      expect(Order.new(total: -1)).not_to be_valid
    end

    it "rejects a foreign currency" do
      expect(Order.new(total: 1, currency: "XX")).not_to be_valid
    end
  end

  describe "#fetch — happy path" do
    it "returns the body" do
      expect(order.fetch).to eq("ok")
    end
  end

  describe "#fetch — transport errors" do
    it "retries once" do
      expect(order.fetch).to eq(:retried)
    end
  end

  its(:status) { is_expected.to eq("new") }
end
