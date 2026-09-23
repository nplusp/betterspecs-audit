RSpec.describe "Users" do
  describe "GET /users" do
    context "when signed out" do
      it "redirects to sign in" do # expect: duplicate-example
        get "/users"
        expect(response).to redirect_to("/session/new")
        expect(flash[:alert]).to eq("Please sign in first")
      end
    end
  end

  describe "GET /users/1" do
    context "when signed out" do
      it "sends you to sign in" do
        get "/users"
        expect(response).to redirect_to("/session/new")
        expect(flash[:alert]).to eq("Please sign in first")
      end
    end
  end

  describe "GET /users/new" do
    context "when signed out" do
      it "asks you to sign in" do
        get   "/users"
        expect(response).to redirect_to("/session/new")
        expect(flash[:alert]).to  eq("Please sign in first")
      end
    end
  end
end
