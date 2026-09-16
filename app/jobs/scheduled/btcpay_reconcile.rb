# frozen_string_literal: true

module Jobs
  class BtcpayReconcile < ::Jobs::Scheduled
    # Sidekiq schedules are frozen at boot, so we tick hourly and let the
    # site setting decide whether this tick actually does any work.
    every 1.hour

    LAST_RUN_KEY = "reconcile_last_run_at"

    def execute(args = {})
      return unless SiteSetting.btcpay_enabled
      return unless due?(force: args && args[:force])

      api = DiscourseBtcpay::BtcpayApi.new
      return unless api.configured?

      manager = DiscourseBtcpay::BtcpaySubscriptionManager.new

      Rails.logger.info("DiscourseBtcpay: Starting reconciliation")

      begin
        remote_subs = api.list_subscriptions
      rescue DiscourseBtcpay::BtcpayApi::ApiError => e
        Rails.logger.error("DiscourseBtcpay: Reconciliation failed to fetch subscriptions: #{e.message}")
        return
      end

      return unless remote_subs.is_a?(Array)

      remote_by_id = remote_subs.index_by { |s| s["id"] }
      local_rows = PluginStoreRow.where(
        plugin_name: DiscourseBtcpay::PLUGIN_NAME
      ).where("key LIKE ?", "sub:%")

      synced = 0
      fixed = 0

      # Check each local subscription against BTCPay
      local_rows.each do |row|
        user_id = row.key.sub("sub:", "").to_i
        local_data = JSON.parse(row.value) rescue next
        sub_id = local_data["subscription_id"]
        next unless sub_id

        remote = remote_by_id[sub_id]

        if remote.nil?
          # Subscription no longer exists in BTCPay
          if local_data["status"] == "active"
            Rails.logger.warn("DiscourseBtcpay: Subscription #{sub_id} not found remotely, deactivating user #{user_id}")
            manager.deactivate(user_id: user_id, reason: "expired")
            fixed += 1
          end
          next
        end

        remote_status = remote["status"]&.downcase
        local_status = local_data["status"]

        # Sync active → expired/cancelled drift
        if local_status == "active" && %w[expired cancelled].include?(remote_status)
          Rails.logger.info("DiscourseBtcpay: Fixing drift: user #{user_id} #{local_status} → #{remote_status}")
          manager.deactivate(user_id: user_id, reason: remote_status)
          fixed += 1

        # Sync expired/cancelled → active drift (missed settlement webhook)
        elsif %w[expired cancelled pending].include?(local_status) && remote_status == "active"
          Rails.logger.info("DiscourseBtcpay: Fixing drift: user #{user_id} #{local_status} → active")
          manager.activate(
            user_id: user_id,
            subscription_id: sub_id,
            plan_id: local_data["plan_id"]
          )
          fixed += 1

        # Update period dates if active and dates changed
        elsif local_status == "active" && remote_status == "active"
          new_start = remote["currentPeriodStart"]
          new_end = remote["currentPeriodEnd"]

          if new_start != local_data["period_start"] || new_end != local_data["period_end"]
            local_data["period_start"] = new_start
            local_data["period_end"] = new_end
            local_data["updated_at"] = Time.now.iso8601
            DiscourseBtcpay.store_subscription(user_id, local_data)
          end
        end

        synced += 1
      end

      # Check for remote active subscriptions with no local record (missed activation)
      remote_subs.each do |remote|
        next unless remote["status"]&.downcase == "active"

        user_id = remote.dig("metadata", "discourse_user_id")&.to_i
        next unless user_id && user_id > 0

        local = DiscourseBtcpay.get_subscription(user_id)
        next if local && local["status"] == "active"

        plan_id = remote["planId"]
        next unless plan_id

        Rails.logger.info("DiscourseBtcpay: Found orphan active subscription #{remote["id"]} for user #{user_id}")
        manager.activate(
          user_id: user_id,
          subscription_id: remote["id"],
          plan_id: plan_id
        )
        fixed += 1
      end

      Rails.logger.info("DiscourseBtcpay: Reconciliation complete. Synced: #{synced}, Fixed: #{fixed}")
    end

    private

    def due?(force: false)
      interval = SiteSetting.btcpay_reconcile_interval_hours.to_i.clamp(1, 168)
      last = PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, LAST_RUN_KEY)
      last_at = Time.parse(last) rescue nil

      if !force && last_at && last_at > interval.hours.ago
        Rails.logger.debug("DiscourseBtcpay: Reconciliation skipped, last run #{last_at}")
        return false
      end

      PluginStore.set(DiscourseBtcpay::PLUGIN_NAME, LAST_RUN_KEY, Time.now.iso8601)
      true
    end
  end
end
