# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayWebhookController do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  let(:secret) { "webhook-secret" }
  let(:payload) do
    {
      type: "InvoiceSettled",
      invoiceId: "INV1",
      subscriptionId: "SUB1",
      metadata: {
        discourse_user_id: user.id.to_s,
        planId: "plan-1"
      }
    }.to_json
  end

  def sign(body)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
  end

  def post_webhook(body, headers: {})
    post "/btcpay/webhook",
         params: body,
         headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_webhook_secret = secret
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_plan_mappings = [
      { plan_id: "plan-1", group_name: "premium", label: "Premium" }
    ].to_json

    stub_request(:get, %r{https://btcpay\.example\.com/api/v1/stores/store/subscriptions/SUB1})
      .to_return(status: 200, body: { currentPeriodEnd: "2026-10-01" }.to_json)
    stub_request(:get, %r{https://btcpay\.example\.com/api/v1/stores/store/invoices/INV1})
      .to_return(status: 200, body: { amount: "10", currency: "USD" }.to_json)
  end

  it "rejects a request with no signature" do
    post_webhook(payload)

    expect(response.status).to eq(401)
    expect(group.users).not_to include(user)
  end

  it "rejects a tampered payload" do
    post_webhook(payload, headers: { "BTCPay-Sig" => sign("something else") })

    expect(response.status).to eq(401)
  end

  it "rejects a non-JSON content type" do
    post_webhook(
      payload,
      headers: { "CONTENT_TYPE" => "text/plain", "BTCPay-Sig" => sign(payload) }
    )

    expect(response.status).to eq(415)
  end

  it "activates the subscription and adds the user to the mapped group" do
    post_webhook(payload, headers: { "BTCPay-Sig" => sign(payload) })

    expect(response.status).to eq(200)
    expect(group.users).to include(user)
    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("active")
  end

  it "ignores a duplicate delivery of the same invoice" do
    2.times { post_webhook(payload, headers: { "BTCPay-Sig" => sign(payload) }) }

    expect(DiscourseBtcpay.get_payments(user.id).size).to eq(1)
  end

  it "rate limits floods from one IP" do
    RateLimiter.enable
    RateLimiter.new(nil, "btcpay-webhook-127.0.0.1", 60, 1.minute).clear!

    61.times { post_webhook(payload, headers: { "BTCPay-Sig" => sign(payload) }) }

    expect(response.status).to eq(429)
  ensure
    RateLimiter.disable
  end
end
