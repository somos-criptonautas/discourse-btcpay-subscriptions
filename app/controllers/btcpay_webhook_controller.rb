# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayWebhookController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    skip_before_action :check_xhr

    def handle
      unless SiteSetting.btcpay_enabled
        return render json: { error: "disabled" }, status: :service_unavailable
      end

      # BTCPay retries failed deliveries; this only stops floods from an
      # unauthenticated endpoint, so keep the ceiling well above normal traffic.
      RateLimiter.new(nil, "btcpay-webhook-#{request.ip}", 60, 1.minute).performed!

      unless request.media_type == "application/json"
        Rails.logger.warn("DiscourseBtcpay: Rejected webhook with content-type #{request.media_type.inspect}")
        return render json: { error: "expected application/json" }, status: :unsupported_media_type
      end

      payload = request.body.read
      signature = request.headers["BTCPay-Sig"]

      unless valid_signature?(payload, signature)
        DiscourseBtcpay.log_hmac_failure
        Rails.logger.warn("DiscourseBtcpay: Invalid webhook signature")
        return render json: { error: "invalid signature" }, status: :unauthorized
      end

      DiscourseBtcpay.reset_hmac_failures

      event = JSON.parse(payload)
      event_type = event["type"]
      Rails.logger.info("DiscourseBtcpay: Received webhook event: #{event_type}")

      case event_type
      when "InvoiceSettled"
        handle_invoice_settled(event)
      when "InvoiceProcessing"
        handle_invoice_processing(event)
      when "InvoiceInvalid"
        handle_invoice_invalid(event)
      when "SubscriptionExpired", "SubscriptionCancelled"
        handle_subscription_ended(event)
      else
        Rails.logger.info("DiscourseBtcpay: Ignoring unhandled event type: #{event_type}")
      end

      render json: { status: "ok" }, status: :ok
    rescue RateLimiter::LimitExceeded
      render json: { error: "rate limited" }, status: :too_many_requests
    rescue JSON::ParserError => e
      Rails.logger.error("DiscourseBtcpay: Invalid webhook JSON: #{e.message}")
      render json: { error: "invalid json" }, status: :bad_request
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Webhook error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      render json: { error: "internal error" }, status: :internal_server_error
    end

    private

    def valid_signature?(payload, signature)
      return false if signature.blank?

      secret = SiteSetting.btcpay_webhook_secret
      return false if secret.blank?

      # BTCPay sends: sha256=HEXDIGEST
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, payload)}"
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def resolve_user_id(event)
      metadata = event.dig("metadata") || {}

      # Primary: user_id in metadata
      user_id = metadata["discourse_user_id"]
      return user_id.to_i if user_id.present? && User.exists?(id: user_id.to_i)

      # Fallback: check subscription metadata via API
      subscription_id = event["subscriptionId"] || metadata["subscriptionId"]
      if subscription_id
        begin
          api = BtcpayApi.new
          sub = api.get_subscription(subscription_id)
          sub_user_id = sub.dig("metadata", "discourse_user_id")
          return sub_user_id.to_i if sub_user_id.present? && User.exists?(id: sub_user_id.to_i)
        rescue BtcpayApi::ApiError => e
          Rails.logger.warn("DiscourseBtcpay: Could not fetch subscription: #{e.message}")
        end
      end

      nil
    end

    def resolve_plan_id(event)
      event.dig("metadata", "planId") || event["planId"]
    end

    def resolve_subscription_id(event)
      event["subscriptionId"] || event.dig("metadata", "subscriptionId")
    end

    def handle_invoice_settled(event)
      invoice_id = event["invoiceId"]

      # Idempotency: skip if already processed
      if DiscourseBtcpay.processed_invoice?(invoice_id)
        Rails.logger.info("DiscourseBtcpay: Invoice #{invoice_id} already processed, skipping")
        return
      end

      user_id = resolve_user_id(event)
      unless user_id
        Rails.logger.error("DiscourseBtcpay: No user found for InvoiceSettled #{invoice_id}")
        return
      end

      subscription_id = resolve_subscription_id(event)
      plan_id = resolve_plan_id(event)

      # Fetch invoice details for payment record
      amount = nil
      currency = nil
      payment_method = nil
      begin
        api = BtcpayApi.new
        invoice = api.get_invoice(invoice_id)
        amount = invoice["amount"]
        currency = invoice["currency"]
        payment_method = invoice["paymentMethod"] || "BTC"
      rescue BtcpayApi::ApiError => e
        Rails.logger.warn("DiscourseBtcpay: Could not fetch invoice details: #{e.message}")
      end

      # If we don't have plan_id, try to get it from existing subscription or BTCPay
      if plan_id.blank? && subscription_id.present?
        existing = DiscourseBtcpay.get_subscription(user_id)
        plan_id = existing&.dig("plan_id")

        if plan_id.blank?
          begin
            api ||= BtcpayApi.new
            sub = api.get_subscription(subscription_id)
            plan_id = sub["planId"]
          rescue BtcpayApi::ApiError
            # Already logged above if needed
          end
        end
      end

      unless plan_id
        Rails.logger.error("DiscourseBtcpay: No plan_id resolved for invoice #{invoice_id}")
        return
      end

      manager = BtcpaySubscriptionManager.new
      result = manager.activate(
        user_id: user_id,
        subscription_id: subscription_id,
        plan_id: plan_id,
        invoice_id: invoice_id,
        amount: amount,
        currency: currency,
        payment_method: payment_method
      )

      DiscourseBtcpay.mark_invoice_processed(invoice_id) if result[:success]
    end

    def handle_invoice_processing(event)
      user_id = resolve_user_id(event)
      return unless user_id

      subscription_id = resolve_subscription_id(event)
      plan_id = resolve_plan_id(event)
      return unless subscription_id && plan_id

      manager = BtcpaySubscriptionManager.new
      manager.mark_pending(user_id: user_id, subscription_id: subscription_id, plan_id: plan_id)
    end

    def handle_invoice_invalid(event)
      invoice_id = event["invoiceId"]
      user_id = resolve_user_id(event)
      return unless user_id

      manager = BtcpaySubscriptionManager.new
      manager.mark_disputed(user_id: user_id, invoice_id: invoice_id)
    end

    def handle_subscription_ended(event)
      subscription_id = resolve_subscription_id(event)
      reason = event["type"] == "SubscriptionCancelled" ? "cancelled" : "expired"

      # Find user by subscription_id in PluginStore
      user_id = resolve_user_id(event)

      unless user_id
        # Search PluginStore for matching subscription_id
        rows = PluginStoreRow.where(
          plugin_name: DiscourseBtcpay::PLUGIN_NAME
        ).where("key LIKE ?", "sub:%")

        rows.each do |row|
          data = JSON.parse(row.value) rescue next
          if data["subscription_id"] == subscription_id
            user_id = row.key.sub("sub:", "").to_i
            break
          end
        end
      end

      unless user_id
        Rails.logger.error("DiscourseBtcpay: No user found for subscription #{subscription_id} (#{reason})")
        return
      end

      manager = BtcpaySubscriptionManager.new
      manager.deactivate(user_id: user_id, reason: reason)
    end
  end
end
