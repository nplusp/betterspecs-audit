RSpec.describe "Menu", type: :system do
  it "closes when you press Escape" do
    visit "/"
    send_keys :escape
    expect(page).to have_no_css("[data-menu-open]")
  end
end
