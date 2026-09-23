RSpec.describe UsersController, type: :controller do # expect: controller-spec
  describe "GET index" do # expect: happy-path-only
    it "assigns users" do
      get :index
      expect(assigns(:users)).to eq([]) # expect: controller-spec
    end
  end
end
