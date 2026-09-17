# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpaySubscriptionManager
    def initialize
      @api = BtcpayApi.new
    end

    # Resolve plan_id to group_name from admin settings
    def group_for_plan(plan_id)
      mapping_for(plan_id)&.dig("group_name")
    end

    def plan_label(plan_id)
      mapping_for(plan_id)&.dig("label") || plan_id
    end

    # Activate: store state + add to group. customer_id is BTCPay's customer id,
    # which is how we address the subscriber from here on.
    def activate(
      user_id:,
      customer_id:,
      plan_id:,
      invoice_id: nil,
      amount: nil,
      currency: nil,
      payment_method: nil,
      subscriber: nil
    )
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

      subscriber ||= fetch_subscriber(customer_id)

      DiscourseBtcpay.store_subscription(user_id, {
        "customer_id" => customer_id,
        "offering_id" => SiteSetting.btcpay_offering_id,
        "plan_id" => plan_id,
        "plan_name" => plan_label(plan_id),
        "group_name" => group_name,
        "status" => "active",
        "phase" => subscriber && subscriber["phase"],
        "auto_renew" => subscriber && subscriber["autoRenew"],
        "period_end" => timestamp(subscriber && subscriber["periodEnd"]),
        "updated_at" => Time.now.iso8601
      })

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

      group.add(user) if group.users.exclude?(user)

      Rails.logger.info("DiscourseBtcpay: Activated subscription for user #{user.username} → group #{group_name}")
      { success: true }
    end

    # InvoiceProcessing — payment seen, not confirmed. No group access yet.
    def mark_pending(user_id:, plan_id:, customer_id: nil)
      existing = DiscourseBtcpay.get_subscription(user_id) || {}

      data = existing.merge({
        "plan_id" => plan_id,
        "plan_name" => plan_label(plan_id),
        "status" => "pending",
        "updated_at" => Time.now.iso8601
      })
      data["customer_id"] = customer_id if customer_id.present?

      DiscourseBtcpay.store_subscription(user_id, data)
      Rails.logger.info("DiscourseBtcpay: Marked subscription pending for user #{user_id}")
    end

    # Deactivate: update state + remove from group
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

    def update_from_subscriber(user_id:, subscriber:)
      sub = DiscourseBtcpay.get_subscription(user_id)
      return unless sub

      sub["phase"] = subscriber["phase"]
      sub["auto_renew"] = subscriber["autoRenew"]
      sub["period_end"] = timestamp(subscriber["periodEnd"])
      sub["updated_at"] = Time.now.iso8601
      DiscourseBtcpay.store_subscription(user_id, sub)
    end

    # Mark as disputed (refund scenario) — keep access, notify admin
    def mark_disputed(user_id:, invoice_id:)
      sub = DiscourseBtcpay.get_subscription(user_id)

      if sub
        sub["status"] = "disputed"
        sub["updated_at"] = Time.now.iso8601
        DiscourseBtcpay.store_subscription(user_id, sub)
      end

      user = User.find_by(id: user_id)
      detail =
        if sub
          "Group access retained pending admin review."
        else
          "No local subscription record exists for this user — nothing was granted."
        end

      DiscourseBtcpay.notify_admin("Subscription Dispute",
        "Invoice #{invoice_id} was invalidated/refunded for user '#{user&.username || user_id}'. " \
        "#{detail}")
    end

    def record_payment(user_id, invoice_id:, amount: nil, currency: nil, payment_method: nil, status: "settled", paid_at: nil)
      payments = DiscourseBtcpay.get_payments(user_id)

      return if payments.any? { |p| p["invoice_id"] == invoice_id }

      payments << {
        "invoice_id" => invoice_id,
        "amount" => amount,
        "currency" => currency,
        "payment_method" => payment_method,
        "status" => status,
        "paid_at" => paid_at || Time.now.iso8601
      }

      DiscourseBtcpay.store_payments(user_id, payments.last(100))
    end

    # All subscriptions from PluginStore (admin view)
    def all_subscriptions
      DiscourseBtcpay.each_subscription.map do |user_id, data|
        user = User.find_by(id: user_id)
        next unless user

        data.merge("user_id" => user_id, "username" => user.username, "email" => user.email)
      end.compact
    end

    private

    def mapping_for(plan_id)
      DiscourseBtcpay.plan_mappings.find { |m| m["plan_id"] == plan_id }
    end

    def fetch_subscriber(customer_id)
      return nil if customer_id.blank?

      @api.subscriber(customer_id)
    rescue BtcpayApi::ApiError => e
      Rails.logger.warn("DiscourseBtcpay: Could not fetch subscriber #{customer_id}: #{e.message}")
      nil
    end

    # BTCPay sends unix timestamps; we store ISO8601
    def timestamp(value)
      return nil if value.blank?

      Time.at(value.to_i).utc.iso8601
    rescue TypeError, RangeError
      nil
    end
  end
end
