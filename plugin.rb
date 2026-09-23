# frozen_string_literal: true

# name: discourse-btcpay-subscriptions
# about: BTCPay Server subscription integration for Discourse
# version: 0.1.0
# authors: Criptonautas
# url: https://github.com/somos-criptonautas/discourse-btcpay-subscriptions
# required_version: 3.4.0

enabled_site_setting :btcpay_enabled

register_asset "stylesheets/btcpay.scss"

# The location is the plugin directory name, so the admin plugin list links
# straight to our dashboard at /admin/plugins/discourse-btcpay-subscriptions.
add_admin_route "btcpay.admin.title", "discourse-btcpay-subscriptions"

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

    PLANS_CACHE_TTL = 10.minutes

    # The offering is the catalogue: plans are read from BTCPay, not typed in
    # twice. Cached per store+offering so a busy page does not hammer it.
    def self.remote_plans(refresh: false)
      api = BtcpayApi.new
      return [] unless api.configured?

      key = "btcpay_plans_#{SiteSetting.btcpay_store_id}_#{SiteSetting.btcpay_offering_id}"
      ::Discourse.cache.delete(key) if refresh

      plans =
        ::Discourse.cache.fetch(key, expires_in: PLANS_CACHE_TTL) do
          begin
            api.plans
          rescue BtcpayApi::ApiError => e
            Rails.logger.warn("DiscourseBtcpay: Could not fetch plans from BTCPay: #{e.message}")
            nil
          end
        end

      plans.is_a?(Array) ? plans : []
    end

    def self.remote_plan(plan_id)
      remote_plans.find { |p| p["id"] == plan_id }
    end

    # A plan earns its Discourse group from, in order: a mapping an admin set
    # on the BTCPay page, `discourse_group` in the plan's own BTCPay metadata,
    # or the default group setting. No JSON to hand-write anywhere.
    def self.plan_groups
      ::PluginStore.get(PLUGIN_NAME, "plan_groups") || {}
    end

    def self.set_plan_group(plan_id, group_name)
      groups = plan_groups
      if group_name.blank?
        groups.delete(plan_id)
      else
        groups[plan_id] = group_name
      end
      ::PluginStore.set(PLUGIN_NAME, "plan_groups", groups)
    end

    def self.group_for_plan(plan_id, plan: nil)
      override = plan_groups[plan_id]
      return override if override.present?

      plan ||= remote_plan(plan_id)
      from_btcpay = plan&.dig("metadata", "discourse_group")
      return from_btcpay if from_btcpay.present?

      SiteSetting.btcpay_default_group.presence
    end

    def self.group_source(plan_id, plan: nil)
      return "admin" if plan_groups[plan_id].present?

      plan ||= remote_plan(plan_id)
      return "btcpay" if plan&.dig("metadata", "discourse_group").present?
      return "default" if SiteSetting.btcpay_default_group.present?

      nil
    end

    def self.label_for_plan(plan_id, plan: nil)
      plan ||= remote_plan(plan_id)
      plan&.dig("name").presence || plan_id
    end

    # Some facts reach us twice — BTCPay fires both InvoiceExpired and
    # InvoiceExpiredPaidPartial for one underpaid invoice — so alerts are
    # deduplicated by a key rather than sent per delivery.
    def self.first_alert?(key)
      seen = ::PluginStore.get(PLUGIN_NAME, "alerts") || []
      return false if seen.include?(key)

      ::PluginStore.set(PLUGIN_NAME, "alerts", (seen << key).last(500))
      true
    end

    # Live payment progress for the invoice a user is currently paying.
    # Short-lived: cleared once the invoice settles, expires or goes invalid.
    def self.store_payment_progress(user_id, progress)
      ::PluginStore.set(PLUGIN_NAME, "progress:#{user_id}", progress)
    end

    def self.get_payment_progress(user_id)
      ::PluginStore.get(PLUGIN_NAME, "progress:#{user_id}")
    end

    def self.clear_payment_progress(user_id)
      ::PluginStore.remove(PLUGIN_NAME, "progress:#{user_id}")
    end

    # One place that knows how subscription rows are stored, so the webhook,
    # the reconcile job and the admin list stop re-deriving it.
    # Ordered by key so a caller can resume from where it stopped.
    def self.each_subscription(after_key: nil, limit: nil)
      return enum_for(:each_subscription, after_key: after_key, limit: limit) unless block_given?

      scope = ::PluginStoreRow.where(plugin_name: PLUGIN_NAME).where("key LIKE ?", "sub:%")
      scope = scope.where("key > ?", after_key) if after_key.present?

      rows = limit ? scope.order(:key).limit(limit) : scope.order(:key)

      rows.each do |row|
        data = JSON.parse(row.value) rescue next
        yield row.key.sub("sub:", "").to_i, data, row.key
      end
    end

    def self.user_id_for_customer(customer_id)
      return nil if customer_id.blank?

      each_subscription do |user_id, data, _key|
        return user_id if data["customer_id"] == customer_id
      end
      nil
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
        notify_admin(:hmac_failures, count: failures[:count])
        failures[:count] = 0
        ::PluginStore.set(PLUGIN_NAME, "hmac_failures", failures)
      end
    end

    def self.reset_hmac_failures
      ::PluginStore.set(PLUGIN_NAME, "hmac_failures", { count: 0, last_at: nil })
    end

    # key → discourse_btcpay.alerts.<key>.{subject,body}, rendered in the
    # recipient admin's locale rather than hardcoded English.
    def self.notify_admin(key, **args)
      with_admin_locale do |admin|
        deliver_admin_message(
          admin,
          I18n.t("discourse_btcpay.alerts.#{key}.subject"),
          I18n.t("discourse_btcpay.alerts.#{key}.body", **args)
        )
      end
    end

    def self.with_admin_locale
      admin = User.where(admin: true).where("id > 0").order(:id).first
      return unless admin

      I18n.with_locale(admin.effective_locale) { yield admin }
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Failed to notify admin: #{e.message}")
    end

    def self.deliver_admin_message(admin, subject, body)
      SystemMessage.create_from_system_user(
        admin,
        :btcpay_admin_notification,
        subject: subject,
        body: body
      )
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

    # JSON only. The admin page itself is an Ember route under
    # adminPlugins.show, so no HTML route may live at this prefix.
    scope "/admin/plugins/btcpay", constraints: StaffConstraint.new, defaults: { format: :json } do
      get "/status" => "discourse_btcpay/admin/btcpay_admin#index"
      get "/subscriptions" => "discourse_btcpay/admin/btcpay_admin#subscriptions"
      post "/plan_group" => "discourse_btcpay/admin/btcpay_admin#plan_group"
      post "/sync" => "discourse_btcpay/admin/btcpay_admin#sync"
    end
  end

  # Plugin-store rows are keyed by user id, so they would outlive the account.
  on(:user_destroyed) do |user|
    %w[sub payments progress].each do |prefix|
      PluginStore.remove(DiscourseBtcpay::PLUGIN_NAME, "#{prefix}:#{user.id}")
    end
  end

  # Add BTCPay tab to user preferences
  add_to_serializer(
    :current_user,
    :btcpay_subscription,
    include_condition: -> { SiteSetting.btcpay_enabled }
  ) do
    sub = DiscourseBtcpay.get_subscription(object.id)
    return nil unless sub
    {
      status: sub["status"],
      plan_name: sub["plan_name"],
      period_end: sub["period_end"]
    }
  end
end
