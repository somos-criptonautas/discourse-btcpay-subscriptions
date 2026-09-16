# frozen_string_literal: true

require "rails_helper"

describe Jobs::BtcpayReconcile do
  before do
    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_reconcile_interval_hours = 6

    stub_request(:get, %r{/api/v1/stores/store/subscriptions})
      .to_return(status: 200, body: [].to_json)
  end

  def last_run
    PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, described_class::LAST_RUN_KEY)
  end

  it "skips ticks inside the configured interval" do
    described_class.new.execute({})
    first_run = last_run
    expect(first_run).to be_present

    freeze_time(1.hour.from_now) { described_class.new.execute({}) }
    expect(last_run).to eq(first_run)
  end

  it "runs again once the interval has elapsed" do
    described_class.new.execute({})
    first_run = last_run

    freeze_time(7.hours.from_now) { described_class.new.execute({}) }
    expect(last_run).not_to eq(first_run)
  end

  it "runs immediately when forced from the admin sync button" do
    described_class.new.execute({})
    first_run = last_run

    freeze_time(1.minute.from_now) { described_class.new.execute({ force: true }) }
    expect(last_run).not_to eq(first_run)
  end
end
