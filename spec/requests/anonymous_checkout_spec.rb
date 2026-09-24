# frozen_string_literal: true

require "rails_helper"

describe "BTCPay anonymous checkout" do
  fab!(:group) { Fabricate(:group, name: "premium") }
  fab!(:admin)

  let(:customer_id) { "cust_anon" }
  let(:secret) { "webhook-secret" }

  let(:checkout_response) do
    { id: "chk_1", invoiceId: "INV9", url: "https://btcpay.example.com/i/INV9" }
  end

  def subscriber(email: "buyer@example.com")
    {
      customer: { id: customer_id, identities: { "Email" => email } },
      plan: { id: "plan-1", name: "Premium" },
      periodEnd: 1.month.from_now.to_i,
      isActive: true,
      phase: "Normal"
    }
  end

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
    SiteSetting.btcpay_webhook_secret = secret
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    DiscourseBtcpay.set_plan_group("plan-1", "premium")

    stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
      .to_return(
        status: 200,
        body: { id: "off-1", plans: [{ id: "plan-1", name: "Premium", price: "10" }] }.to_json
      )
    stub_request(:get, %r{/offerings/off-1/subscribers/}).to_return(
      status: 200,
      body: subscriber.to_json
    )
    stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
      .to_return(status: 200, body: checkout_response.to_json)
    stub_request(:post, %r{/api/v1/plan-checkout/chk_1})
      .to_return(status: 200, body: { id: "chk_1", invoiceId: "INV9" }.to_json)
  end

  it "refuses a logged-out buyer by default" do
    post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

    expect(response.status).to eq(403)
  end

  context "when anonymous checkout is enabled" do
    before { SiteSetting.btcpay_anonymous_checkout = true }

    it "lets a logged-out visitor start a checkout without an email of ours" do
      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req|
            body = JSON.parse(req.body)
            body["newSubscriberEmail"].nil? &&
              body["newSubscriberMetadata"]["discourse_anonymous"] == "true"
          }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
    end

    it "invites the payer and grants the group through the invite" do
      expect { deliver(type: "PlanStarted", subscriber: subscriber) }.to change {
        Invite.count
      }.by(1)

      invite = Invite.last
      expect(invite.email).to eq("buyer@example.com")
      expect(invite.invited_groups.first.group_id).to eq(group.id)
      expect(DiscourseBtcpay.get_claim("buyer@example.com")["plan_id"]).to eq("plan-1")
    end

    it "attaches the subscription when the invited buyer signs up" do
      deliver(type: "PlanStarted", subscriber: subscriber)

      user = Fabricate(:user, email: "buyer@example.com")

      stored = DiscourseBtcpay.get_subscription(user.id)
      expect(stored["status"]).to eq("active")
      expect(stored["customer_id"]).to eq(customer_id)
      expect(group.reload.users).to include(user)
      expect(DiscourseBtcpay.get_claim("buyer@example.com")).to be_nil
    end

    it "uses an existing account rather than inviting when the email is known" do
      user = Fabricate(:user, email: "buyer@example.com")

      expect { deliver(type: "PlanStarted", subscriber: subscriber) }.not_to change {
        Invite.count
      }

      expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("active")
      expect(group.reload.users).to include(user)
    end
  end
end
