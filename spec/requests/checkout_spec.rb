# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayCheckoutController do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
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

    it "404s on an unmapped plan" do
      post "/btcpay/checkout.json", params: { plan_id: "nope" }

      expect(response.status).to eq(404)
    end

    it "returns the BTCPay checkout URL" do
      stub_request(:post, %r{/api/v1/stores/store/subscriptions/plans/plan-1/checkouts})
        .to_return(
          status: 200,
          body: { checkoutUrl: "https://btcpay.example.com/i/abc" }.to_json
        )

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(200)
      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/abc"
      )
    end

    it "rate limits repeated checkout attempts" do
      RateLimiter.enable
      RateLimiter.new(user, "btcpay-checkout", 5, 1.minute).clear!
      RateLimiter.new(user, "btcpay-checkout-hourly", 20, 1.hour).clear!

      stub_request(:post, %r{/checkouts})
        .to_return(status: 200, body: { checkoutUrl: "https://x/i/abc" }.to_json)

      6.times { post "/btcpay/checkout.json", params: { plan_id: "plan-1" } }

      expect(response.status).to eq(429)
    ensure
      RateLimiter.disable
    end

    it "lists plans straight from the JSON setting" do
      stub_request(:get, %r{/api/v1/stores/store/subscriptions/plans})
        .to_return(status: 200, body: [].to_json)

      get "/btcpay/plans.json"

      expect(response.parsed_body["plans"].first["group_name"]).to eq("premium")
    end
  end
end
