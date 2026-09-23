RSpec.describe "Orders" do
  describe "POST /orders" do
    context "with valid params" do
      it "creates an order" do
        post "/orders", params: {order: {total: 1}}
        expect(response).to redirect_to("/orders/1")
        expect(Order.count).to eq(1)
      end
    end

    context "with invalid params" do
      it "renders the form again" do
        post "/orders", params: {order: {total: nil}}
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end
end
