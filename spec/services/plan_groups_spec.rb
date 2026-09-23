# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpaySubscriptionManager do
  let(:plan) { { "id" => "p1", "name" => "Premium" } }

  before do
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
  end

  it "grants nothing when a plan has no group anywhere" do
    expect(DiscourseBtcpay.group_for_plan("p1", plan: plan)).to be_nil
    expect(DiscourseBtcpay.group_source("p1", plan: plan)).to be_nil
  end

  it "falls back to the default group setting" do
    SiteSetting.btcpay_default_group = "members"

    expect(DiscourseBtcpay.group_for_plan("p1", plan: plan)).to eq("members")
    expect(DiscourseBtcpay.group_source("p1", plan: plan)).to eq("default")
  end

  it "prefers the plan's own BTCPay metadata over the default" do
    SiteSetting.btcpay_default_group = "members"
    with_metadata = plan.merge("metadata" => { "discourse_group" => "premium" })

    expect(DiscourseBtcpay.group_for_plan("p1", plan: with_metadata)).to eq("premium")
    expect(DiscourseBtcpay.group_source("p1", plan: with_metadata)).to eq("btcpay")
  end

  it "prefers what an admin set over everything else" do
    SiteSetting.btcpay_default_group = "members"
    with_metadata = plan.merge("metadata" => { "discourse_group" => "premium" })
    DiscourseBtcpay.set_plan_group("p1", "vip")

    expect(DiscourseBtcpay.group_for_plan("p1", plan: with_metadata)).to eq("vip")
    expect(DiscourseBtcpay.group_source("p1", plan: with_metadata)).to eq("admin")
  end

  it "clears an admin mapping when it is blanked" do
    DiscourseBtcpay.set_plan_group("p1", "vip")
    DiscourseBtcpay.set_plan_group("p1", nil)

    expect(DiscourseBtcpay.plan_groups).to eq({})
    expect(DiscourseBtcpay.group_for_plan("p1", plan: plan)).to be_nil
  end

  it "labels a plan from BTCPay, falling back to its id" do
    expect(DiscourseBtcpay.label_for_plan("p1", plan: plan)).to eq("Premium")
    expect(DiscourseBtcpay.label_for_plan("p9", plan: { "id" => "p9" })).to eq("p9")
  end

  it "resolves the group through the manager" do
    DiscourseBtcpay.set_plan_group("p1", "vip")

    expect(described_class.new.group_for_plan("p1", plan: plan)).to eq("vip")
  end
end
