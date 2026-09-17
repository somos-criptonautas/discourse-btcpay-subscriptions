# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayCheckoutController do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  let(:checkout_response) do
    {
      id: "chk_1",
      invoiceId: "INV9",
      url: "https://btcpay.example.com/i/INV9",
      subscriber: { customer: { id: "cust_abc123" } }
    }
  end

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    SiteSetting.btcpay_plan_mappings = [
      { plan_id: "plan-1", group_name: "premium", label: "Premium" }
    ].to_json
  end

  it "requires a logged in user" do
    post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

    expect(response.status).to eq(403)
  end

  context "when logged in" do
    before { sign_in(user) }

    it "refuses when the offering is not configured" do
      SiteSetting.btcpay_offering_id = ""

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(503)
    end

    it "404s on an unmapped plan" do
      post "/btcpay/checkout.json", params: { plan_id: "nope" }

      expect(response.status).to eq(404)
    end

    it "posts a store-scoped body to the top-level plan-checkout endpoint" do
      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req|
            body = JSON.parse(req.body)
            body["storeId"] == "store" && body["offeringId"] == "off-1" &&
              body["planId"] == "plan-1" &&
              body["invoiceMetadata"]["discourse_user_id"] == user.id.to_s
          }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
      expect(response.parsed_body["invoice_id"]).to eq("INV9")
      expect(response.parsed_body["modal_url"]).to eq(
        "https://btcpay.example.com/modal/btcpay.js"
      )
    end

    it "remembers the BTCPay customer id for later lookups" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(DiscourseBtcpay.get_subscription(user.id)["customer_id"]).to eq("cust_abc123")
    end

    it "sends a returning subscriber as the customer selector" do
      DiscourseBtcpay.store_subscription(user.id, { "customer_id" => "cust_abc123" })

      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req| JSON.parse(req.body)["customerSelector"] == "cust_abc123" }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(stub).to have_been_requested
    end

    it "rate limits repeated checkout attempts" do
      RateLimiter.enable
      RateLimiter.new(user, "btcpay-checkout", 5, 1.minute).clear!
      RateLimiter.new(user, "btcpay-checkout-hourly", 20, 1.hour).clear!

      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.to_json)

      6.times { post "/btcpay/checkout.json", params: { plan_id: "plan-1" } }

      expect(response.status).to eq(429)
    ensure
      RateLimiter.disable
    end

    it "prices plans from the offering and caches them" do
      stub =
        stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
          .to_return(
            status: 200,
            body: {
              id: "off-1",
              plans: [
                {
                  id: "plan-1",
                  name: "Premium",
                  price: "10",
                  currency: "USD",
                  recurringType: "Monthly"
                }
              ]
            }.to_json
          )

      2.times { get "/btcpay/plans.json" }

      plan = response.parsed_body["plans"].first
      expect(plan["price"]).to eq("10")
      expect(plan["currency"]).to eq("USD")
      expect(plan["interval"]).to eq("Monthly")
      expect(plan["group_name"]).to eq("premium")
      expect(stub).to have_been_requested.once
    end

    it "still lists plans when BTCPay is unreachable" do
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_timeout

      get "/btcpay/plans.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["plans"].first["label"]).to eq("Premium")
      expect(response.parsed_body["plans"].first["price"]).to be_nil
    end

    it "returns a real portal session url" do
      DiscourseBtcpay.store_subscription(
        user.id,
        { "customer_id" => "cust_abc123", "status" => "active" }
      )
      stub_request(:post, "https://btcpay.example.com/api/v1/subscriber-portal")
        .to_return(
          status: 200,
          body: { url: "https://btcpay.example.com/portal/sess_1" }.to_json
        )

      get "/btcpay/subscription.json"

      expect(response.parsed_body["portal_url"]).to eq(
        "https://btcpay.example.com/portal/sess_1"
      )
    end
  end
end
