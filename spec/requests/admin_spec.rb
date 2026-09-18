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
    before { sign_in(admin) }

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

    it "queues a forced reconcile" do
      post "/admin/plugins/btcpay/sync.json"

      expect(response.status).to eq(200)
      expect(
        Jobs::BtcpayReconcile.jobs.last["args"].first["force"]
      ).to eq(true)
    end
  end
end
