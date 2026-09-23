RSpec.describe User do
  fixtures :users # expect: fixtures

  describe "full_name" do # expect: describe-method
    it "joins first and last" do
      expect(User.new(first: "A", last: "B").full_name).to eq("A B")
    end
  end

  describe "the authenticate method" do # expect: describe-method
    it "authenticates" do
      expect(described_class.authenticate("a")).to be_nil
    end
  end

  describe "when admin" do # expect: describe-as-context
    it "is an admin" do
      expect(build(:user, :admin)).to be_admin
    end
  end

  describe "#admin?" do
    context "admin user" do # expect: context-wording
      it "returns true" do
        expect(build(:user, :admin).admin?).to be(true) # expect: weak-matcher
      end
    end

    it "returns false when the role is missing" do # expect: description-conditional
      expect(build(:user).admin?).to be_falsey # expect: weak-matcher
    end
  end

  describe "#display_name" do # expect: happy-path-only
    it "should return the name if it is present and nobody overrode it" do # expect: description-length, should-wording, description-conditional
      user = build(:user)
      user.name.should == "x" # expect: should-syntax
    end
  end

  describe "#initials" do
    subject(:user) { build(:user, first: "Ada", last: "Lovelace") }

    it "returns the initials" do # expect: multiple-expectations
      expect(user.initials).to eq("AL")
      expect(user.initials).to be_frozen
    end

    it "is empty without names" do
      allow(user).to receive(:first).and_return(nil) # expect: stubbed-subject
      expect(user.initials).to eq("")
    end

    it "saves the initials" do
      expect(user).to receive(:save!) # expect: stubbed-subject, stubbed-persistence
      user.initials
    end
  end

  describe ".top" do # expect: happy-path-only
    before { @users = create_list(:user, 25) } # expect: instance-variable, large-data

    it "returns the top two" do
      expect(described_class.top(2).size).to eq(2)
    end
  end

  describe ".active" do
    let!(:inactive) { create(:user, active: false) } # expect: unreferenced-let-bang
    let!(:active) { create(:user, active: true) }

    it "excludes inactive users" do
      expect(described_class.active).to eq([active])
    end
  end

  describe "#greeting" do # expect: missing-subject
    it "greets by first name" do
      expect(described_class.new(first: "Ada").greeting).to eq("Hi Ada")
    end

    it "is capitalized" do
      expect(described_class.new(first: "Ada").greeting).to start_with("H")
    end

    it "is not blank for blank names" do
      expect(described_class.new( first: "Ada" ).greeting).not_to be_empty
    end
  end

  describe "#sync" do # expect: happy-path-only
    it "calls the api" do
      allow_any_instance_of(ApiClient).to receive(:get) # expect: any-instance
      allow(ApiClient).to receive_message_chain(:new, :get) # expect: message-chain
      allow(User).to receive(:find).and_return(nil) # expect: stubbed-persistence
      User.stub(:where) # expect: should-syntax
      expect(build(:user).sync).to eq(true)
    end
  end

  describe "#save!" do
    it "raises without an email" do
      expect(lambda { build(:user, email: nil).save! }).to raise_error(ActiveRecord::RecordInvalid) # expect: lambda-expectation
    end
  end

  describe ".create" do # expect: happy-path-only
    it "persists a record" do
      user = User.create!(name: "A", email: "a@b.c", active: true) # expect: raw-create
      expect(user).to be_persisted
    end
  end

  describe "#tags" do
    it "is empty for a new user" do
      expect(build(:user).tags.count).to eq(0) # expect: weak-matcher
    end

    it "matches the other tags" do
      expect(build(:user).tags == []).to be true # expect: weak-matcher
    end

    it "includes the default tag" do
      expect(build(:user).tags.include?("new")).to be_truthy # expect: weak-matcher
    end

    it "builds many" do
      30.times { create(:tag) } # expect: large-data
      expect(Tag.count).to eq(30)
    end

    it { should be_valid } # expect: should-syntax
  end
end
