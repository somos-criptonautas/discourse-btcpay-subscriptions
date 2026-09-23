# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::Admin::BtcpayAdminController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
  end

  it "refuses non-staff" do
    sign_in(user)

    get "/admin/plugins/btcpay/status.json"

    expect(response.status).to eq(404)
  end

  context "as an admin" do
    before do
      sign_in(admin)
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(status: 200, body: { id: "off-1", plans: [] }.to_json)
    end

    it "names the settings that are still blank" do
      SiteSetting.btcpay_offering_id = ""

      get "/admin/plugins/btcpay/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["configured"]).to eq(false)
      expect(response.parsed_body["missing_settings"]).to eq(["btcpay_offering_id"])
    end

    it "reports the network from the chain tip" do
      stub_request(:get, "https://btcpay.example.com/api/v1/server/info").to_return(
        status: 200,
        body: {
          version: "2.4.4",
          fullySynched: true,
          syncStatus: [{ cryptoCode: "BTC", chainHeight: 2_900_000 }]
        }.to_json
      )

      get "/admin/plugins/btcpay/status.json"

      body = response.parsed_body
      expect(body["configured"]).to eq(true)
      expect(body["reachable"]).to eq(true)
      expect(body["network"]).to eq("testnet")
      expect(body["cryptos"]).to eq(["BTC"])
    end

    it "stays configured but flags BTCPay as unreachable" do
      stub_request(:get, "https://btcpay.example.com/api/v1/server/info").to_timeout

      get "/admin/plugins/btcpay/status.json"

      expect(response.parsed_body["configured"]).to eq(true)
      expect(response.parsed_body["reachable"]).to eq(false)
    end

    it "lists subscriptions with their payment counts" do
      group = Fabricate(:group, name: "premium")
      DiscourseBtcpay.store_subscription(
        user.id,
        { "plan_id" => "plan-1", "group_name" => group.name, "status" => "active" }
      )

      get "/admin/plugins/btcpay/subscriptions.json"

      expect(response.parsed_body["total"]).to eq(1)
      expect(response.parsed_body["active"]).to eq(1)
      expect(response.parsed_body["subscriptions"].first["username"]).to eq(user.username)
    end

    it "lists the offering's plans with the group they resolve to" do
      Fabricate(:group, name: "premium")
      DiscourseBtcpay.set_plan_group("plan-1", "premium")
      stub_request(:get, "https://btcpay.example.com/api/v1/server/info").to_return(
        status: 200,
        body: { version: "2.4.4", fullySynched: true, syncStatus: [] }.to_json
      )
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: {
            id: "off-1",
            plans: [
              { id: "plan-1", name: "Premium", price: "10", currency: "USD" },
              { id: "plan-9", name: "Orphan", price: "5", currency: "USD" }
            ]
          }.to_json
        )

      get "/admin/plugins/btcpay/status.json"

      plans = response.parsed_body["plans"]
      expect(plans.first["group_name"]).to eq("premium")
      expect(plans.first["source"]).to eq("admin")
      expect(plans.first["group_exists"]).to eq(true)
      expect(plans.second["group_name"]).to be_nil
      expect(response.parsed_body["groups"]).to include("premium")
    end

    it "assigns a group to a plan" do
      Fabricate(:group, name: "premium")

      post "/admin/plugins/btcpay/plan_group.json",
           params: { plan_id: "plan-1", group_name: "premium" }

      expect(response.status).to eq(200)
      expect(DiscourseBtcpay.plan_groups["plan-1"]).to eq("premium")
    end

    it "clears a plan's group when a blank option is sent" do
      DiscourseBtcpay.set_plan_group("plan-1", "premium")

      post "/admin/plugins/btcpay/plan_group.json", params: { plan_id: "plan-1", group_name: "" }

      expect(DiscourseBtcpay.plan_groups).to eq({})
    end

    it "refuses a group that does not exist" do
      post "/admin/plugins/btcpay/plan_group.json",
           params: { plan_id: "plan-1", group_name: "nope" }

      expect(response.status).to eq(422)
      expect(DiscourseBtcpay.plan_groups).to eq({})
    end

    it "queues a forced reconcile" do
      post "/admin/plugins/btcpay/sync.json"

      expect(response.status).to eq(200)
      expect(
        Jobs::BtcpayReconcile.jobs.last["args"].first["force"]
      ).to eq(true)
    end
  end
end
