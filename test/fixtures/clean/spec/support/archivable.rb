RSpec.shared_examples "an archivable record" do
  let!(:unused_here) { create(:order) }

  it "archives" do
    expect { subject.archive }.to change(subject, :archived?).to(true)
  end
end
