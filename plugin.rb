# frozen_string_literal: true

# name: discourse-btcpay-subscriptions
# about: BTCPay Server subscription integration for Discourse
# version: 0.1.0
# authors: Criptonautas
# url: https://github.com/somos-criptonautas/discourse-btcpay-subscriptions
# required_version: 2.7.0

enabled_site_setting :btcpay_enabled

register_asset "stylesheets/btcpay.scss"

after_initialize do
  module ::DiscourseBtcpay
    PLUGIN_NAME = "discourse-btcpay-subscriptions"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseBtcpay
    end

    def self.store_subscription(user_id, data)
      ::PluginStore.set(PLUGIN_NAME, "sub:#{user_id}", data)
    end

    def self.get_subscription(user_id)
      ::PluginStore.get(PLUGIN_NAME, "sub:#{user_id}")
    end

    def self.store_payments(user_id, payments)
      ::PluginStore.set(PLUGIN_NAME, "payments:#{user_id}", payments)
    end

    def self.get_payments(user_id)
      ::PluginStore.get(PLUGIN_NAME, "payments:#{user_id}") || []
    end

    def self.store_plans(plans)
      ::PluginStore.set(PLUGIN_NAME, "plans", plans)
    end

    def self.get_plans
      ::PluginStore.get(PLUGIN_NAME, "plans") || []
    end

    # Single source of truth for plan → group mappings.
    # Setting is one JSON array in a textarea — parsed once, here.
    def self.plan_mappings
      raw = SiteSetting.btcpay_plan_mappings.to_s.strip
      return [] if raw.empty?

      parsed = JSON.parse(raw)
      return [] unless parsed.is_a?(Array)

      parsed.select { |m| m.is_a?(Hash) && m["plan_id"].present? }
    rescue JSON::ParserError => e
      Rails.logger.error("DiscourseBtcpay: btcpay_plan_mappings is not valid JSON: #{e.message}")
      []
    end

    def self.processed_invoice?(invoice_id)
      processed = ::PluginStore.get(PLUGIN_NAME, "processed_invoices") || []
      processed.include?(invoice_id)
    end

    def self.mark_invoice_processed(invoice_id)
      processed = ::PluginStore.get(PLUGIN_NAME, "processed_invoices") || []
      return if processed.include?(invoice_id)
      processed << invoice_id
      # Keep last 1000 to prevent unbounded growth
      processed = processed.last(1000)
      ::PluginStore.set(PLUGIN_NAME, "processed_invoices", processed)
    end

    def self.log_hmac_failure
      failures = ::PluginStore.get(PLUGIN_NAME, "hmac_failures") || { count: 0, last_at: nil }
      failures[:count] += 1
      failures[:last_at] = Time.now.iso8601
      ::PluginStore.set(PLUGIN_NAME, "hmac_failures", failures)

      if failures[:count] >= 3
        notify_admin("BTCPay HMAC Validation Failing",
          "#{failures[:count]} consecutive HMAC failures detected. " \
          "Check that your webhook secret matches between BTCPay and Discourse settings.")
        failures[:count] = 0
        ::PluginStore.set(PLUGIN_NAME, "hmac_failures", failures)
      end
    end

    def self.reset_hmac_failures
      ::PluginStore.set(PLUGIN_NAME, "hmac_failures", { count: 0, last_at: nil })
    end

    def self.notify_admin(subject, body)
      admin = User.find_by(admin: true)
      return unless admin

      SystemMessage.create_from_system_user(
        admin,
        :btcpay_admin_notification,
        subject: subject,
        body: body
      )
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Failed to notify admin: #{e.message}")
    end
  end

  require_relative "app/services/btcpay_api"
  require_relative "app/services/btcpay_subscription_manager"
  require_relative "app/controllers/btcpay_webhook_controller"
  require_relative "app/controllers/btcpay_checkout_controller"
  require_relative "app/controllers/admin/btcpay_admin_controller"
  require_relative "app/jobs/scheduled/btcpay_reconcile"

  # Routes
  DiscourseBtcpay::Engine.routes.draw do
    post "/webhook" => "btcpay_webhook#handle"
    post "/checkout" => "btcpay_checkout#create"
    get "/subscription" => "btcpay_checkout#status"
    get "/plans" => "btcpay_checkout#plans"
  end

  Discourse::Application.routes.append do
    mount DiscourseBtcpay::Engine, at: "/btcpay"

    scope "/admin/plugins/btcpay", constraints: StaffConstraint.new do
      get "/" => "discourse_btcpay/admin/btcpay_admin#index"
      get "/subscriptions" => "discourse_btcpay/admin/btcpay_admin#subscriptions"
      post "/sync" => "discourse_btcpay/admin/btcpay_admin#sync"
    end
  end

  # Add BTCPay tab to user preferences
  add_to_serializer(:current_user, :btcpay_subscription) do
    sub = DiscourseBtcpay.get_subscription(object.id)
    return nil unless sub
    {
      status: sub["status"],
      plan_name: sub["plan_name"],
      period_end: sub["period_end"]
    }
  end
end
