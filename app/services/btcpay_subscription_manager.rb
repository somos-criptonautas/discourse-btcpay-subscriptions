# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpaySubscriptionManager
    def initialize
      @api = BtcpayApi.new
    end

    # Resolve plan_id to group_name from admin settings
    def group_for_plan(plan_id)
      mappings = plan_mappings
      mapping = mappings.find { |m| m["plan_id"] == plan_id }
      mapping&.dig("group_name")
    end

    def plan_label(plan_id)
      mappings = plan_mappings
      mapping = mappings.find { |m| m["plan_id"] == plan_id }
      mapping&.dig("label") || plan_id
    end

    # Activate subscription: store state + add to group
    def activate(user_id:, subscription_id:, plan_id:, invoice_id: nil, amount: nil, currency: nil, payment_method: nil)
      user = User.find_by(id: user_id)
      unless user
        Rails.logger.error("DiscourseBtcpay: User #{user_id} not found for activation")
        return { success: false, error: :user_not_found }
      end

      group_name = group_for_plan(plan_id)
      unless group_name
        Rails.logger.error("DiscourseBtcpay: No group mapping for plan #{plan_id}")
        DiscourseBtcpay.notify_admin("Plan Mapping Missing",
          "Received payment for plan '#{plan_id}' but no group mapping exists. User: #{user.username}")
        return { success: false, error: :plan_not_found }
      end

      group = Group.find_by(name: group_name)
      unless group
        Rails.logger.error("DiscourseBtcpay: Group '#{group_name}' not found")
        DiscourseBtcpay.notify_admin("Group Not Found",
          "Tried to add user '#{user.username}' to group '#{group_name}' but group doesn't exist.")
        return { success: false, error: :group_not_found }
      end

      # Fetch subscription details from BTCPay for period info
      period_start = nil
      period_end = nil
      begin
        btcpay_sub = @api.get_subscription(subscription_id)
        period_start = btcpay_sub["currentPeriodStart"]
        period_end = btcpay_sub["currentPeriodEnd"]
      rescue BtcpayApi::ApiError => e
        Rails.logger.warn("DiscourseBtcpay: Could not fetch subscription details: #{e.message}")
      end

      # Store subscription state
      DiscourseBtcpay.store_subscription(user_id, {
        "subscription_id" => subscription_id,
        "plan_id" => plan_id,
        "plan_name" => plan_label(plan_id),
        "group_name" => group_name,
        "status" => "active",
        "period_start" => period_start,
        "period_end" => period_end,
        "updated_at" => Time.now.iso8601
      })

      # Record payment
      if invoice_id
        record_payment(user_id,
          invoice_id: invoice_id,
          amount: amount,
          currency: currency,
          payment_method: payment_method,
          status: "settled",
          paid_at: Time.now.iso8601
        )
      end

      # Add to group (idempotent)
      group.add(user) if group.users.exclude?(user)

      Rails.logger.info("DiscourseBtcpay: Activated subscription for user #{user.username} → group #{group_name}")
      { success: true }
    end

    # Mark subscription as pending (InvoiceProcessing — seen in mempool, not confirmed)
    def mark_pending(user_id:, subscription_id:, plan_id:)
      existing = DiscourseBtcpay.get_subscription(user_id)

      data = (existing || {}).merge({
        "subscription_id" => subscription_id,
        "plan_id" => plan_id,
        "plan_name" => plan_label(plan_id),
        "status" => "pending",
        "updated_at" => Time.now.iso8601
      })

      DiscourseBtcpay.store_subscription(user_id, data)
      Rails.logger.info("DiscourseBtcpay: Marked subscription pending for user #{user_id}")
    end

    # Deactivate subscription: update state + remove from group
    def deactivate(user_id:, reason: "expired")
      user = User.find_by(id: user_id)
      sub = DiscourseBtcpay.get_subscription(user_id)
      return { success: false, error: :user_not_found } unless user && sub

      group_name = sub["group_name"]
      group = Group.find_by(name: group_name) if group_name

      if group
        group.remove(user) if group.users.include?(user)
      else
        Rails.logger.warn("DiscourseBtcpay: Group '#{group_name}' not found during deactivation")
      end

      sub["status"] = reason
      sub["updated_at"] = Time.now.iso8601
      DiscourseBtcpay.store_subscription(user_id, sub)

      Rails.logger.info("DiscourseBtcpay: Deactivated subscription for user #{user.username} (#{reason})")
      { success: true }
    end

    # Mark as disputed (refund scenario) — keep access, notify admin
    def mark_disputed(user_id:, invoice_id:)
      sub = DiscourseBtcpay.get_subscription(user_id)
      return unless sub

      sub["status"] = "disputed"
      sub["updated_at"] = Time.now.iso8601
      DiscourseBtcpay.store_subscription(user_id, sub)

      user = User.find_by(id: user_id)
      DiscourseBtcpay.notify_admin("Subscription Dispute",
        "Invoice #{invoice_id} was invalidated/refunded for user '#{user&.username || user_id}'. " \
        "Group access retained pending admin review.")
    end

    # Record a payment in history
    def record_payment(user_id, invoice_id:, amount: nil, currency: nil, payment_method: nil, status: "settled", paid_at: nil)
      payments = DiscourseBtcpay.get_payments(user_id)

      # Dedup by invoice_id
      return if payments.any? { |p| p["invoice_id"] == invoice_id }

      payments << {
        "invoice_id" => invoice_id,
        "amount" => amount,
        "currency" => currency,
        "payment_method" => payment_method,
        "status" => status,
        "paid_at" => paid_at || Time.now.iso8601
      }

      # Keep last 100 payments per user
      payments = payments.last(100)
      DiscourseBtcpay.store_payments(user_id, payments)
    end

    # Get all subscriptions from PluginStore (for admin view)
    def all_subscriptions
      rows = PluginStoreRow.where(
        plugin_name: DiscourseBtcpay::PLUGIN_NAME
      ).where("key LIKE ?", "sub:%")

      rows.filter_map do |row|
        user_id = row.key.sub("sub:", "").to_i
        user = User.find_by(id: user_id)
        next unless user

        data = JSON.parse(row.value) rescue nil
        next unless data

        data.merge("user_id" => user_id, "username" => user.username, "email" => user.email)
      end
    end

    private

    def plan_mappings
      DiscourseBtcpay.plan_mappings
    end
  end
end
