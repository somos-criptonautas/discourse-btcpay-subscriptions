# frozen_string_literal: true

require "rails_helper"

describe "DiscourseBtcpay.plan_mappings" do
  it "returns [] for blank or malformed settings" do
    SiteSetting.btcpay_plan_mappings = ""
    expect(DiscourseBtcpay.plan_mappings).to eq([])

    SiteSetting.btcpay_plan_mappings = "not json"
    expect(DiscourseBtcpay.plan_mappings).to eq([])

    SiteSetting.btcpay_plan_mappings = '{"plan_id":"x"}'
    expect(DiscourseBtcpay.plan_mappings).to eq([])
  end

  it "drops entries with no plan_id" do
    SiteSetting.btcpay_plan_mappings = [
      { group_name: "premium" },
      { plan_id: "p1", group_name: "premium" }
    ].to_json

    expect(DiscourseBtcpay.plan_mappings.map { |m| m["plan_id"] }).to eq(["p1"])
  end

  it "resolves the group for a plan" do
    SiteSetting.btcpay_plan_mappings = [
      { plan_id: "p1", group_name: "premium", label: "Premium" }
    ].to_json

    manager = DiscourseBtcpay::BtcpaySubscriptionManager.new
    expect(manager.group_for_plan("p1")).to eq("premium")
    expect(manager.plan_label("p1")).to eq("Premium")
    expect(manager.group_for_plan("nope")).to be_nil
  end
end
