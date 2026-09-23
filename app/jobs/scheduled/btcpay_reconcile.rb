# frozen_string_literal: true

module Jobs
  class BtcpayReconcile < ::Jobs::Scheduled
    # Sidekiq schedules are frozen at boot, so we tick hourly and let the
    # site setting decide whether this tick actually does any work.
    every 1.hour

    LAST_RUN_KEY = "reconcile_last_run_at"
    CURSOR_KEY = "reconcile_cursor"
    PENDING_TIMEOUT = 24.hours
    # One BTCPay call per subscriber, up to 25s each: cap the tick so a slow
    # BTCPay cannot hold a Sidekiq worker for hours. The cursor makes the next
    # tick resume where this one stopped.
    MAX_PER_TICK = 200

    # BTCPay has no "list all subscribers" endpoint — subscribers are addressed
    # one selector at a time — so we walk our own records and ask about each.
    def execute(args = {})
      return unless SiteSetting.btcpay_enabled
      return unless due?(force: args && args[:force])

      api = DiscourseBtcpay::BtcpayApi.new
      return unless api.configured?

      manager = DiscourseBtcpay::BtcpaySubscriptionManager.new

      Rails.logger.info("DiscourseBtcpay: Starting reconciliation")

      checked = 0
      fixed = 0
      failures = 0
      seen = 0
      last_key = nil
      cursor = PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, CURSOR_KEY)

      DiscourseBtcpay.each_subscription(
        after_key: cursor,
        limit: MAX_PER_TICK
      ) do |user_id, local, key|
        seen += 1
        last_key = key
        customer_id = local["customer_id"]

        if customer_id.blank?
          fixed += 1 if expire_stale_pending(manager, user_id, local)
          next
        end

        begin
          remote = api.subscriber(customer_id)
        rescue DiscourseBtcpay::BtcpayApi::NotFound
          # The subscriber is gone from BTCPay entirely
          if local["status"] == "active"
            Rails.logger.warn("DiscourseBtcpay: Subscriber #{customer_id} not found remotely, deactivating user #{user_id}")
            manager.deactivate(user_id: user_id, reason: "expired")
            fixed += 1
          end
          next
        rescue DiscourseBtcpay::BtcpayApi::ApiError => e
          Rails.logger.error("DiscourseBtcpay: Could not fetch subscriber #{customer_id}: #{e.message}")
          failures += 1
          next
        end

        checked += 1
        fixed += 1 if reconcile_one(manager, user_id, local, remote)
      end

      # A short page means the tail was reached: wrap the cursor and only then
      # count the sweep as done for this interval.
      completed = seen < MAX_PER_TICK
      PluginStore.set(DiscourseBtcpay::PLUGIN_NAME, CURSOR_KEY, completed ? "" : last_key)

      # A tick that could not reach BTCPay at all should not consume the
      # window — the next hourly tick retries instead of waiting N hours.
      mark_ran if completed && !(checked.zero? && failures.positive?)

      Rails.logger.info(
        "DiscourseBtcpay: Reconciliation pass done. Checked: #{checked}, Fixed: #{fixed}, " \
          "Failures: #{failures}, Resuming at: #{completed ? "start" : last_key}"
      )
    end

    private

    def reconcile_one(manager, user_id, local, remote)
      active_remotely = remote["isActive"] && !remote["isSuspended"]
      local_status = local["status"]
      plan_id = remote.dig("plan", "id") || local["plan_id"]

      if local_status == "active" && !active_remotely
        reason = remote["isSuspended"] ? "cancelled" : "expired"
        Rails.logger.info("DiscourseBtcpay: Fixing drift: user #{user_id} active → #{reason}")
        manager.deactivate(user_id: user_id, reason: reason)
        return true
      end

      if %w[expired cancelled pending].include?(local_status) && active_remotely && plan_id
        Rails.logger.info("DiscourseBtcpay: Fixing drift: user #{user_id} #{local_status} → active")
        manager.activate(
          user_id: user_id,
          customer_id: local["customer_id"],
          plan_id: plan_id,
          subscriber: remote
        )
        return true
      end

      manager.update_from_subscriber(user_id: user_id, subscriber: remote) if local_status == "active"
      false
    end

    # A pending record with no customer id never got as far as a subscriber.
    def expire_stale_pending(manager, user_id, local)
      return false unless local["status"] == "pending" && stale_pending?(local)

      Rails.logger.warn("DiscourseBtcpay: Pending subscription never settled, expiring user #{user_id}")
      manager.deactivate(user_id: user_id, reason: "expired")
      true
    end

    def due?(force: false)
      return true if force

      interval = SiteSetting.btcpay_reconcile_interval_hours.to_i.clamp(1, 168)
      last = PluginStore.get(DiscourseBtcpay::PLUGIN_NAME, LAST_RUN_KEY)
      last_at = Time.parse(last) rescue nil

      if last_at && last_at > interval.hours.ago
        Rails.logger.debug("DiscourseBtcpay: Reconciliation skipped, last run #{last_at}")
        return false
      end

      true
    end

    def mark_ran
      PluginStore.set(DiscourseBtcpay::PLUGIN_NAME, LAST_RUN_KEY, Time.now.iso8601)
    end

    # BTCPay invoices expire in minutes; a day is a generous grace period
    # before we treat the payment as abandoned.
    def stale_pending?(local)
      updated = Time.parse(local["updated_at"].to_s) rescue nil
      updated.nil? || updated < PENDING_TIMEOUT.ago
    end
  end
end
