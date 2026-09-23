# frozen_string_literal: true

require "rails_helper"

describe Jobs::BtcpayReconcile do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  let(:customer_id) { "cust_abc123" }
  let(:subscriber_url) do
    "https://btcpay.example.com/api/v1/stores/store/offerings/off-1/subscribers/#{customer_id}"
  end

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    SiteSetting.btcpay_reconcile_interval_hours = 6
    SiteSetting.btcpay_plan_mappings = [
      { plan_id: "plan-1", group_name: "premium", label: "Premium" }
    ].to_json
  end

  def store(status:, updated_at: Time.now, customer: customer_id)
    data = {
      "plan_id" => "plan-1",
      "group_name" => "premium",
      "status" => status,
      "updated_at" => updated_at.iso8601
    }
    data["customer_id"] = customer if customer
    DiscourseBtcpay.store_subscription(user.id, data)
  end

  def remote(active: true, suspended: false, phase: "Normal")
    {
      customer: { id: customer_id },
      plan: { id: "plan-1" },
      periodEnd: 1.month.from_now.to_i,
      isActive: active,
      isSuspended: suspended,
      phase: phase
    }
  end

  def last_run
    PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, described_class::LAST_RUN_KEY)
  end

  it "grants the group when a settlement webhook was missed" do
    store(status: "pending")
    stub_request(:get, subscriber_url).to_return(status: 200, body: remote.to_json)

    described_class.new.execute({})

    expect(group.reload.users).to include(user)
    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("active")
  end

  it "revokes the group when BTCPay says the subscriber lapsed" do
    store(status: "active")
    group.add(user)
    stub_request(:get, subscriber_url).to_return(
      status: 200,
      body: remote(active: false, phase: "Expired").to_json
    )

    described_class.new.execute({})

    expect(group.reload.users).not_to include(user)
  end

  it "deactivates when the subscriber is gone from BTCPay" do
    store(status: "active")
    group.add(user)
    stub_request(:get, subscriber_url).to_return(status: 404, body: "{}")

    described_class.new.execute({})

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("expired")
  end

  it "does not consume the interval when BTCPay is unreachable" do
    store(status: "active")
    stub_request(:get, subscriber_url).to_timeout

    described_class.new.execute({})

    expect(last_run).to be_nil
  end

  it "expires a pending subscription that never reached BTCPay" do
    store(status: "pending", updated_at: 2.days.ago, customer: nil)

    described_class.new.execute({})

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("expired")
  end

  it "leaves a freshly pending subscription alone" do
    store(status: "pending", updated_at: 1.hour.ago, customer: nil)

    described_class.new.execute({})

    expect(DiscourseBtcpay.get_subscription(user.id)["status"]).to eq("pending")
  end

  it "caps a tick and resumes from the cursor on the next one" do
    stub_const(described_class, "MAX_PER_TICK", 1) do
      other = Fabricate(:user)
      store(status: "active")
      DiscourseBtcpay.store_subscription(
        other.id,
        {
          "customer_id" => "cust_other",
          "plan_id" => "plan-1",
          "group_name" => "premium",
          "status" => "active"
        }
      )
      stub_request(:get, subscriber_url).to_return(status: 200, body: remote.to_json)
      stub_request(:get, subscriber_url.sub(customer_id, "cust_other")).to_return(
        status: 200,
        body: remote.to_json
      )

      described_class.new.execute({})
      expect(
        PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, described_class::CURSOR_KEY)
      ).to be_present
      # A capped tick is not a finished sweep, so the interval is not consumed
      expect(last_run).to be_nil

      described_class.new.execute({})
      expect(
        PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, described_class::CURSOR_KEY)
      ).to eq("")
      expect(last_run).to be_present
    end
  end

  it "skips ticks inside the configured interval" do
    store(status: "active")
    stub_request(:get, subscriber_url).to_return(status: 200, body: remote.to_json)

    described_class.new.execute({})
    first_run = last_run
    expect(first_run).to be_present

    freeze_time(1.hour.from_now) { described_class.new.execute({}) }
    expect(last_run).to eq(first_run)
  end

  it "runs again once the interval has elapsed" do
    store(status: "active")
    stub_request(:get, subscriber_url).to_return(status: 200, body: remote.to_json)

    described_class.new.execute({})
    first_run = last_run

    freeze_time(7.hours.from_now) { described_class.new.execute({}) }
    expect(last_run).not_to eq(first_run)
  end

  it "runs immediately when forced from the admin sync button" do
    store(status: "active")
    stub_request(:get, subscriber_url).to_return(status: 200, body: remote.to_json)

    described_class.new.execute({})
    first_run = last_run

    freeze_time(1.minute.from_now) { described_class.new.execute({ force: true }) }
    expect(last_run).not_to eq(first_run)
  end
end
