# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayWebhookController do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  let(:secret) { "webhook-secret" }
  let(:customer_id) { "cust_abc123" }

  def subscriber(phase: "Normal", active: true, suspended: false)
    {
      customer: { id: customer_id, metadata: { discourse_user_id: user.id.to_s } },
      plan: { id: "plan-1", name: "Premium", price: "10", currency: "USD" },
      periodEnd: 1.month.from_now.to_i,
      trialEnd: 3.days.from_now.to_i,
      gracePeriodEnd: 5.days.from_now.to_i,
      isActive: active,
      isSuspended: suspended,
      autoRenew: true,
      phase: phase
    }
  end

  def sign(body)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
  end

  def post_webhook(body, headers: {})
    post "/btcpay/webhook",
         params: body,
         headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  def deliver(payload)
    body = payload.to_json
    post_webhook(body, headers: { "BTCPay-Sig" => sign(body) })
  end

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_webhook_secret = secret
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    SiteSetting.btcpay_plan_mappings = [
      { plan_id: "plan-1", group_name: "premium", label: "Premium" }
    ].to_json

    stub_request(
      :get,
      %r{https://btcpay\.example\.com/api/v1/stores/store/offerings/off-1/subscribers/}
    ).to_return(status: 200, body: subscriber.to_json)

    stub_request(:get, %r{https://btcpay\.example\.com/api/v1/stores/store/invoices/INV1$})
      .to_return(status: 200, body: { amount: "10", currency: "USD" }.to_json)
    stub_request(
      :get,
      %r{https://btcpay\.example\.com/api/v1/stores/store/invoices/INV1/payment-methods}
    ).to_return(
      status: 200,
      body: [{ paymentMethodId: "XMR", paymentMethodPaid: "10.0" }].to_json
    )
  end

  it "rejects a request with no signature" do
    post_webhook({ type: "PlanStarted" }.to_json)

    expect(response.status).to eq(401)
    expect(group.reload.users).not_to include(user)
  end

  it "rejects a tampered payload" do
    body = { type: "PlanStarted", subscriber: subscriber }.to_json
    post_webhook(body, headers: { "BTCPay-Sig" => sign("something else") })

    expect(response.status).to eq(401)
  end

  it "rejects a non-JSON content type" do
    body = { type: "PlanStarted", subscriber: subscriber }.to_json
    post_webhook(
      body,
      headers: { "CONTENT_TYPE" => "text/plain", "BTCPay-Sig" => sign(body) }
    )

    expect(response.status).to eq(415)
  end

  it "grants the mapped group when the plan starts" do
    deliver(type: "PlanStarted", storeId: "store", subscriber: subscriber)

    expect(response.status).to eq(200)
    expect(group.reload.users).to include(user)

    stored = DiscourseBtcpay.get_subscription(user.id)
    expect(stored["status"]).to eq("active")
    expect(stored["customer_id"]).to eq(customer_id)
    expect(stored["plan_name"]).to eq("Premium")
  end

  it "records the crypto that actually settled the invoice" do
    deliver(
      type: "InvoiceSettled",
      invoiceId: "INV1",
      metadata: { discourse_user_id: user.id.to_s, discourse_plan_id: "plan-1" }
    )

    payment = DiscourseBtcpay.get_payments(user.id).first
    expect(payment["payment_method"]).to eq("XMR")
    expect(payment["currency"]).to eq("USD")
  end

  it "ignores a duplicate invoice delivery" do
    2.times do
      deliver(
        type: "InvoiceSettled",
        invoiceId: "INV1",
        metadata: { discourse_user_id: user.id.to_s, discourse_plan_id: "plan-1" }
      )
    end

    expect(DiscourseBtcpay.get_payments(user.id).size).to eq(1)
  end

  it "revokes access when the subscriber is disabled by expiration" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    deliver(type: "SubscriberDisabled", reason: "Expiration", subscriber: subscriber(active: false))

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("expired")
    expect(group.reload.users).not_to include(user)
  end

  it "marks a suspension as cancelled" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    deliver(
      type: "SubscriberDisabled",
      reason: "Suspension",
      subscriber: subscriber(active: false, suspended: true)
    )

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("cancelled")
  end

  it "revokes access when the phase changes to Expired" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    deliver(
      type: "SubscriberPhaseChanged",
      subscriber: subscriber(phase: "Expired", active: false)
    )

    expect(group.reload.users).not_to include(user)
  end

  it "keeps access through the grace phase" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    deliver(type: "SubscriberPhaseChanged", subscriber: subscriber(phase: "Grace"))

    expect(group.reload.users).to include(user)
    expect(DiscourseBtcpay.get_subscription(user.id)["phase"]).to eq("Grace")
  end

  it "marks the subscription pending while the payment confirms" do
    deliver(
      type: "InvoiceProcessing",
      invoiceId: "INV2",
      metadata: { discourse_user_id: user.id.to_s, discourse_plan_id: "plan-1" }
    )

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("pending")
    expect(group.reload.users).not_to include(user)
  end

  it "clears a pending subscription when the invoice expires" do
    deliver(
      type: "InvoiceProcessing",
      invoiceId: "INV2",
      metadata: { discourse_user_id: user.id.to_s, discourse_plan_id: "plan-1" }
    )

    deliver(type: "InvoiceExpired", invoiceId: "INV2", metadata: { discourse_user_id: user.id.to_s })

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("expired")
  end

  it "leaves an active subscription alone when an unrelated invoice expires" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    deliver(type: "InvoiceExpired", invoiceId: "INV2", metadata: { discourse_user_id: user.id.to_s })

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("active")
    expect(group.reload.users).to include(user)
  end

  it "identifies the user by stored customer id when metadata is absent" do
    deliver(type: "PlanStarted", subscriber: subscriber)

    bare = { customer: { id: customer_id }, plan: { id: "plan-1" }, isActive: false, phase: "Expired" }
    deliver(type: "SubscriberDisabled", reason: "Expiration", subscriber: bare)

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("expired")
  end

  it "notifies an admin about a dispute even with no local record" do
    Fabricate(:admin)

    expect {
      deliver(type: "InvoiceInvalid", invoiceId: "INV3", metadata: { discourse_user_id: user.id.to_s })
    }.to change { Topic.where(archetype: Archetype.private_message).count }.by(1)
  end

  it "stores the trial and grace dates from the subscriber" do
    deliver(type: "PlanStarted", subscriber: subscriber(phase: "Trial"))

    stored = DiscourseBtcpay.get_subscription(user.id)
    expect(stored["phase"]).to eq("Trial")
    expect(stored["trial_end"]).to be_present
    expect(stored["grace_period_end"]).to be_present
    expect(stored["auto_renew"]).to eq(true)
  end

  it "records a scheduled plan change" do
    upgrade = subscriber.merge(
      scheduledPlan: { id: "plan-2", name: "VIP" },
      scheduledPlanActivatesAt: 1.month.from_now.to_i
    )

    deliver(type: "PlanStarted", subscriber: upgrade)

    stored = DiscourseBtcpay.get_subscription(user.id)
    expect(stored["next_plan_id"]).to eq("plan-2")
    expect(stored["next_plan_name"]).to eq("VIP")
    expect(stored["next_plan_at"]).to be_present
  end

  it "tracks an unconfirmed payment as progress" do
    deliver(
      type: "InvoiceReceivedPayment",
      invoiceId: "INV1",
      paymentMethodId: "BTC",
      payment: { id: "pay-1", value: "0.0004", status: "Processing" },
      metadata: { discourse_user_id: user.id.to_s }
    )

    progress = DiscourseBtcpay.get_payment_progress(user.id)
    expect(progress["invoice_id"]).to eq("INV1")
    expect(progress["payments"].first["value"]).to eq("0.0004")
    expect(progress["payments"].first["settled"]).to eq(false)
  end

  it "flips the same payment to settled instead of duplicating it" do
    payment = { id: "pay-1", value: "0.0004", status: "Processing" }

    deliver(
      type: "InvoiceReceivedPayment",
      invoiceId: "INV1",
      paymentMethodId: "BTC",
      payment: payment,
      metadata: { discourse_user_id: user.id.to_s }
    )
    deliver(
      type: "InvoicePaymentSettled",
      invoiceId: "INV1",
      paymentMethodId: "BTC",
      payment: payment.merge(status: "Settled"),
      metadata: { discourse_user_id: user.id.to_s }
    )

    progress = DiscourseBtcpay.get_payment_progress(user.id)
    expect(progress["payments"].size).to eq(1)
    expect(progress["payments"].first["settled"]).to eq(true)
  end

  it "clears payment progress once the invoice settles" do
    deliver(
      type: "InvoiceReceivedPayment",
      invoiceId: "INV1",
      paymentMethodId: "BTC",
      payment: { id: "pay-1", value: "0.0004" },
      metadata: { discourse_user_id: user.id.to_s }
    )
    deliver(
      type: "InvoiceSettled",
      invoiceId: "INV1",
      metadata: { discourse_user_id: user.id.to_s, discourse_plan_id: "plan-1" }
    )

    expect(DiscourseBtcpay.get_payment_progress(user.id)).to be_nil
  end

  it "rate limits floods from one IP" do
    RateLimiter.enable
    RateLimiter.new(nil, "btcpay-webhook-127.0.0.1", 60, 1.minute).clear!

    61.times { deliver(type: "PlanStarted", subscriber: subscriber) }

    expect(response.status).to eq(429)
  ensure
    RateLimiter.disable
  end
end
