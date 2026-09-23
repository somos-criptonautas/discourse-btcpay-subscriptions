# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpaySubscriptionManager
    def initialize
      @api = BtcpayApi.new
    end

    # Mapping setting first, then the plan's own BTCPay metadata
    def group_for_plan(plan_id, plan: nil)
      DiscourseBtcpay.group_for_plan(plan_id, plan: plan)
    end

    def plan_label(plan_id, plan: nil)
      DiscourseBtcpay.label_for_plan(plan_id, plan: plan)
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

      group_name = group_for_plan(plan_id, plan: subscriber&.dig("plan"))
      unless group_name
        Rails.logger.error("DiscourseBtcpay: No group mapping for plan #{plan_id}")
        DiscourseBtcpay.notify_admin(:plan_unmapped, plan_id: plan_id, username: user.username)
        return { success: false, error: :plan_not_found }
      end

      group = Group.find_by(name: group_name)
      unless group
        Rails.logger.error("DiscourseBtcpay: Group '#{group_name}' not found")
        DiscourseBtcpay.notify_admin(:group_missing, username: user.username, group: group_name)
        return { success: false, error: :group_not_found }
      end

      subscriber ||= fetch_subscriber(customer_id)

      DiscourseBtcpay.store_subscription(user_id, {
        "customer_id" => customer_id,
        "offering_id" => SiteSetting.btcpay_offering_id,
        "plan_id" => plan_id,
        "plan_name" => plan_label(plan_id, plan: subscriber&.dig("plan")),
        "group_name" => group_name,
        "status" => "active",
        "needs_upgrade" => false,
        "updated_at" => Time.now.iso8601
      }.merge(subscriber_fields(subscriber)))

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

      DiscourseBtcpay.store_subscription(
        user_id,
        sub.merge(subscriber_fields(subscriber)).merge("updated_at" => Time.now.iso8601)
      )
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
        I18n.t("discourse_btcpay.alerts.dispute.#{sub ? "retained" : "no_record"}")

      DiscourseBtcpay.notify_admin(
        :dispute,
        invoice_id: invoice_id,
        username: user&.username || user_id,
        detail: detail
      )
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
      DiscourseBtcpay.each_subscription.map do |user_id, data, _key|
        user = User.find_by(id: user_id)
        next unless user

        data.merge("user_id" => user_id, "username" => user.username, "email" => user.email)
      end.compact
    end

    private

    # Everything we mirror from BTCPay's SubscriberModel
    def subscriber_fields(subscriber)
      return {} if subscriber.blank?

      scheduled = subscriber["scheduledPlan"] || subscriber["nextPlan"]

      {
        "phase" => subscriber["phase"],
        "auto_renew" => subscriber["autoRenew"],
        "period_end" => timestamp(subscriber["periodEnd"]),
        "trial_end" => timestamp(subscriber["trialEnd"]),
        "grace_period_end" => timestamp(subscriber["gracePeriodEnd"]),
        "next_plan_id" => scheduled && scheduled["id"],
        "next_plan_name" => scheduled && (scheduled["name"] || plan_label(scheduled["id"])),
        "next_plan_at" => timestamp(subscriber["scheduledPlanActivatesAt"])
      }
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
