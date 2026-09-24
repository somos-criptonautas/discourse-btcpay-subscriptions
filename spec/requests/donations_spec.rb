# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayDonationsController do
  fab!(:user)
  fab!(:badge) { Fabricate(:badge, name: "Supporter") }

  let(:secret) { "webhook-secret" }
  let(:pos_url) { "https://btcpay.example.com/apps/pos-1/pos" }

  def deliver(payload)
    body = payload.to_json
    post "/btcpay/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "BTCPay-Sig" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
         }
  end

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_donations_enabled = true
    SiteSetting.btcpay_webhook_secret = secret
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    SiteSetting.btcpay_pos_app_id = "pos-1"
    SiteSetting.btcpay_donation_min = 1
  end

  it "refuses donations when the feature is off" do
    SiteSetting.btcpay_donations_enabled = false
    sign_in(user)

    post "/btcpay/donate.json", params: { amount: "10" }

    expect(response.status).to eq(503)
  end

  it "requires an account so the donation can be attributed" do
    post "/btcpay/donate.json", params: { amount: "10" }

    expect(response.status).to eq(403)
  end

  context "when logged in" do
    before { sign_in(user) }

    it "creates a POS invoice with a server-generated order id" do
      stub =
        stub_request(:post, pos_url)
          .with { |req|
            body = URI.decode_www_form(req.body).to_h
            body["amount"] == "10.0" &&
              body["orderId"].start_with?("btcpay-donation:#{user.id}:")
          }
          .to_return(status: 200, body: { invoiceId: "INV-D1" }.to_json)

      post "/btcpay/donate.json", params: { amount: "10" }

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
      expect(response.parsed_body["invoice_id"]).to eq("INV-D1")
      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/INV-D1"
      )
    end

    it "refuses an amount below the minimum" do
      SiteSetting.btcpay_donation_min = 5

      post "/btcpay/donate.json", params: { amount: "2" }

      expect(response.status).to eq(422)
    end
  end

  describe "a settled donation" do
    def settle(invoice_id: "INV-D1", amount: "10", order_user: user)
      deliver(
        type: "InvoiceSettled",
        invoiceId: invoice_id,
        metadata: {
          orderId: "btcpay-donation:#{order_user.id}:abc123",
          itemTotal: amount
        }
      )
    end

    it "credits the donor and never touches groups" do
      settle

      donor = PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, "donor:#{user.id}")
      expect(donor["total"]).to eq(10.0)
      expect(donor["count"]).to eq(1)
      expect(DiscourseBtcpay.get_subscription(user.id)).to be_nil
    end

    it "counts a redelivery only once" do
      2.times { settle }

      expect(
        PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, "donor:#{user.id}")["count"]
      ).to eq(1)
    end

    it "grants the configured donor badge" do
      DiscourseBtcpay.set_donor_badge(badge.id)

      expect { settle }.to change { UserBadge.where(badge_id: badge.id, user_id: user.id).count }.by(1)
    end

    it "totals donations for the fundraising bar" do
      settle(invoice_id: "INV-D1", amount: "10")
      settle(invoice_id: "INV-D2", amount: "15")

      get "/btcpay/donations.json"

      body = response.parsed_body
      expect(body["total"]).to eq(25.0)
      expect(body["count"]).to eq(2)
      expect(body["currency"]).to eq("USD")
      expect(body["supporters"].first["username"]).to eq(user.username)
      expect(body["supporters"].first["amount"]).to eq(25.0)
    end
  end
end
