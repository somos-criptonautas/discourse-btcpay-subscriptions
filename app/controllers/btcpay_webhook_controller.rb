# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayWebhookController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    skip_before_action :check_xhr

    # Invoice events tell us about money; subscriber events tell us about access.
    # Both are needed: an invoice can settle before BTCPay starts the plan.
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
      when "PlanStarted", "SubscriberActivated"
        handle_plan_started(event)
      when "SubscriberCreated"
        handle_subscriber_created(event)
      when "SubscriberCharged"
        handle_subscriber_charged(event)
      when "SubscriberCredited"
        handle_subscriber_credited(event)
      when "SubscriberNeedUpgrade"
        handle_need_upgrade(event)
      when "SubscriberDisabled"
        handle_subscriber_disabled(event)
      when "SubscriberPhaseChanged"
        handle_phase_changed(event)
      when "InvoiceSettled"
        handle_invoice_settled(event)
      when "InvoiceProcessing"
        handle_invoice_processing(event)
      when "InvoiceReceivedPayment", "InvoicePaymentSettled"
        handle_payment_progress(event)
      when "InvoiceExpired"
        handle_invoice_expired(event)
      when "InvoiceExpiredPaidPartial"
        handle_expired_paid_partial(event)
      when "InvoicePaidAfterExpiration"
        handle_paid_after_expiration(event)
      when "InvoiceRefund"
        handle_invoice_refund(event)
      when "InvoiceInvalid"
        handle_invoice_invalid(event)
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

    # Subscriber events carry the whole SubscriberModel
    def subscriber_of(event)
      event["subscriber"]
    end

    def customer_id_of(event)
      subscriber_of(event)&.dig("customer", "id")
    end

    # We tag both the subscriber and the invoice with discourse_user_id at
    # checkout, so either side of the payload can identify the user. The stored
    # customer id is the fallback for subscribers created outside Discourse.
    def resolve_user_id(event)
      subscriber = subscriber_of(event)

      candidates = [
        event.dig("metadata", "discourse_user_id"),
        subscriber&.dig("metadata", "discourse_user_id"),
        subscriber&.dig("customer", "metadata", "discourse_user_id")
      ]

      candidates.each do |candidate|
        next if candidate.blank?
        return candidate.to_i if User.exists?(id: candidate.to_i)
      end

      DiscourseBtcpay.user_id_for_customer(customer_id_of(event) || event["customerId"])
    end

    def plan_id_of(event)
      subscriber_of(event)&.dig("plan", "id") || event.dig("metadata", "discourse_plan_id")
    end

    def handle_plan_started(event)
      user_id = resolve_user_id(event)
      subscriber = subscriber_of(event)
      plan_id = plan_id_of(event)

      unless user_id && plan_id
        Rails.logger.error("DiscourseBtcpay: PlanStarted without a resolvable user/plan")
        return
      end

      BtcpaySubscriptionManager.new.activate(
        user_id: user_id,
        customer_id: customer_id_of(event),
        plan_id: plan_id,
        subscriber: subscriber
      )
    end

    # reason is "Suspension" or "Expired"
    def handle_subscriber_disabled(event)
      user_id = resolve_user_id(event)
      return unless user_id

      reason = event["reason"].to_s.casecmp("suspension").zero? ? "cancelled" : "expired"
      BtcpaySubscriptionManager.new.deactivate(user_id: user_id, reason: reason)
    end

    # phases: Trial, Normal, Grace, Expired
    def handle_phase_changed(event)
      user_id = resolve_user_id(event)
      subscriber = subscriber_of(event)
      return unless user_id && subscriber

      manager = BtcpaySubscriptionManager.new

      if subscriber["phase"].to_s.casecmp("expired").zero? || subscriber["isActive"] == false
        manager.deactivate(user_id: user_id, reason: "expired")
      else
        manager.update_from_subscriber(user_id: user_id, subscriber: subscriber)
      end
    end

    def handle_invoice_settled(event)
      invoice_id = event["invoiceId"]

      if DiscourseBtcpay.processed_invoice?(invoice_id)
        Rails.logger.info("DiscourseBtcpay: Invoice #{invoice_id} already processed, skipping")
        return
      end

      user_id = resolve_user_id(event)
      unless user_id
        Rails.logger.error("DiscourseBtcpay: No user found for InvoiceSettled #{invoice_id}")
        return
      end

      amount = nil
      currency = nil
      payment_method = nil

      begin
        api = BtcpayApi.new
        invoice = api.invoice(invoice_id)
        amount = invoice["amount"]
        currency = invoice["currency"]
        # Whatever BTCPay actually took — BTC, XMR, LTC, Lightning, …
        payment_method = api.settled_payment_method(invoice_id)
      rescue BtcpayApi::ApiError => e
        Rails.logger.warn("DiscourseBtcpay: Could not fetch invoice details: #{e.message}")
      end

      if event["manuallyMarked"]
        Rails.logger.warn("DiscourseBtcpay: Invoice #{invoice_id} was marked settled by hand")
      end

      if event["overPaid"] && DiscourseBtcpay.first_alert?("over:#{invoice_id}")
        DiscourseBtcpay.notify_admin(:overpaid, invoice_id: invoice_id)
      end

      existing = DiscourseBtcpay.get_subscription(user_id)
      plan_id = plan_id_of(event) || event.dig("metadata", "planId") || existing&.dig("plan_id")
      customer_id = customer_id_of(event) || existing&.dig("customer_id")

      manager = BtcpaySubscriptionManager.new

      if plan_id.blank?
        # Money arrived but we cannot tell which tier — record it and let
        # PlanStarted (or reconcile) grant access.
        Rails.logger.warn("DiscourseBtcpay: No plan resolved for invoice #{invoice_id}, recording payment only")
        manager.record_payment(user_id,
          invoice_id: invoice_id, amount: amount, currency: currency, payment_method: payment_method)
        return
      end

      result = manager.activate(
        user_id: user_id,
        customer_id: customer_id,
        plan_id: plan_id,
        invoice_id: invoice_id,
        amount: amount,
        currency: currency,
        payment_method: payment_method
      )

      DiscourseBtcpay.clear_payment_progress(user_id)
      DiscourseBtcpay.mark_invoice_processed(invoice_id) if result[:success]
    end

    # On-chain payments take minutes to hours. These two events are the only
    # signal the payer gets that anything is happening, so we mirror them into
    # a short-lived record the billing page can poll.
    def handle_payment_progress(event)
      user_id = resolve_user_id(event)
      return unless user_id

      payment = event["payment"] || {}
      settled = event["type"] == "InvoicePaymentSettled"

      progress = DiscourseBtcpay.get_payment_progress(user_id) || {}
      progress = {} if progress["invoice_id"] != event["invoiceId"]

      entries = Array(progress["payments"])
      entry = entries.find { |p| p["id"] == payment["id"] } if payment["id"].present?

      if entry
        entry["status"] = payment["status"] || (settled ? "Settled" : entry["status"])
        entry["settled"] = settled || entry["settled"]
      else
        entries << {
          "id" => payment["id"],
          "value" => payment["value"],
          "method" => event["paymentMethodId"],
          "status" => payment["status"] || (settled ? "Settled" : "Processing"),
          "settled" => settled,
          "after_expiration" => event["afterExpiration"],
          "received_at" => payment["receivedDate"] || Time.now.iso8601
        }
      end

      DiscourseBtcpay.store_payment_progress(user_id, {
        "invoice_id" => event["invoiceId"],
        "payments" => entries.last(20),
        "updated_at" => Time.now.iso8601
      })
    end

    def handle_invoice_processing(event)
      user_id = resolve_user_id(event)
      return unless user_id

      plan_id = plan_id_of(event) || event.dig("metadata", "planId")
      return unless plan_id

      BtcpaySubscriptionManager.new.mark_pending(
        user_id: user_id,
        plan_id: plan_id,
        customer_id: customer_id_of(event)
      )
    end

    # BTCPay has no "subscriber gained access again" event other than this one
    # and PlanStarted, so an unsuspension arrives here.
    def handle_subscriber_created(event)
      user_id = resolve_user_id(event)
      customer_id = customer_id_of(event)
      return unless user_id && customer_id

      sub = DiscourseBtcpay.get_subscription(user_id) || {}
      return if sub["customer_id"] == customer_id

      # Access is not granted here — only the identity is recorded.
      DiscourseBtcpay.store_subscription(
        user_id,
        sub.merge("customer_id" => customer_id, "updated_at" => Time.now.iso8601)
      )
    end

    # A renewal paid out of the subscriber's BTCPay credit balance: real money
    # moved, but no invoice exists, so record it from the event itself.
    def handle_subscriber_charged(event)
      user_id = resolve_user_id(event)
      subscriber = subscriber_of(event)
      return unless user_id

      manager = BtcpaySubscriptionManager.new
      manager.record_payment(
        user_id,
        invoice_id: "credit-#{delivery_key(event)}",
        amount: event["amount"],
        currency: event["currency"],
        payment_method: "credit",
        status: "settled"
      )
      manager.update_from_subscriber(user_id: user_id, subscriber: subscriber) if subscriber
    end

    def handle_subscriber_credited(event)
      user_id = resolve_user_id(event)
      return unless user_id

      BtcpaySubscriptionManager.new.record_payment(
        user_id,
        invoice_id: "credited-#{delivery_key(event)}",
        amount: event["amount"],
        currency: event["currency"],
        payment_method: "credit",
        status: "credited"
      )
    end

    # The subscriber's plan can no longer carry them (plan withdrawn, seats
    # exceeded). Nothing is revoked automatically — staff decides.
    def handle_need_upgrade(event)
      user_id = resolve_user_id(event)
      return unless user_id

      sub = DiscourseBtcpay.get_subscription(user_id)
      if sub
        DiscourseBtcpay.store_subscription(
          user_id,
          sub.merge("needs_upgrade" => true, "updated_at" => Time.now.iso8601)
        )
      end

      user = User.find_by(id: user_id)
      DiscourseBtcpay.notify_admin(:needs_upgrade, username: user&.username || user_id)
    end

    # An invoice that was never paid in time. Only a pending record is
    # affected — a settled subscription keeps its access.
    def handle_invoice_expired(event)
      user_id = resolve_user_id(event)
      return unless user_id

      # Money arrived but not enough: expiring silently would lose it.
      report_partial_payment(user_id, event["invoiceId"]) if event["partiallyPaid"]

      DiscourseBtcpay.clear_payment_progress(user_id)

      sub = DiscourseBtcpay.get_subscription(user_id)
      return unless sub && sub["status"] == "pending"

      Rails.logger.info("DiscourseBtcpay: Invoice expired for user #{user_id}, clearing pending subscription")
      BtcpaySubscriptionManager.new.deactivate(user_id: user_id, reason: "expired")
    end

    # BTCPay's own event for the same situation, fired alongside (or instead
    # of) InvoiceExpired depending on which boxes the admin ticked.
    def handle_expired_paid_partial(event)
      user_id = resolve_user_id(event)
      return unless user_id

      report_partial_payment(user_id, event["invoiceId"])
      DiscourseBtcpay.clear_payment_progress(user_id)

      sub = DiscourseBtcpay.get_subscription(user_id)
      return unless sub && sub["status"] == "pending"

      BtcpaySubscriptionManager.new.deactivate(user_id: user_id, reason: "expired")
    end

    # Paid late: the invoice had already expired, so BTCPay grants nothing and
    # the money is sitting there. Staff has to settle or refund it by hand.
    def handle_paid_after_expiration(event)
      user_id = resolve_user_id(event)
      invoice_id = event["invoiceId"]
      return unless user_id
      return unless DiscourseBtcpay.first_alert?("late:#{invoice_id}")

      user = User.find_by(id: user_id)
      DiscourseBtcpay.notify_admin(
        :paid_late,
        invoice_id: invoice_id,
        username: user&.username || user_id
      )
    end

    # A refund was created against the invoice (BTCPay opens a pull payment).
    def handle_invoice_refund(event)
      user_id = resolve_user_id(event)
      invoice_id = event["invoiceId"]
      return unless user_id
      return unless DiscourseBtcpay.first_alert?("refund:#{invoice_id}")

      user = User.find_by(id: user_id)
      DiscourseBtcpay.notify_admin(
        :refunded,
        invoice_id: invoice_id,
        username: user&.username || user_id,
        pull_payment_id: event["pullPaymentId"] || "n/a"
      )
    end

    # Credit events carry no invoice, so the delivery identifies them.
    # originalDeliveryId is stable across BTCPay's retries; the digest is the
    # fallback for a payload that carries neither.
    def delivery_key(event)
      id = event["originalDeliveryId"].presence || event["deliveryId"].presence
      return id if id

      Digest::SHA1.hexdigest(
        [event["type"], event["amount"], event["currency"], event.dig("subscriber", "customer", "id")].join(":")
      )[0, 16]
    end

    def report_partial_payment(user_id, invoice_id)
      return unless DiscourseBtcpay.first_alert?("partial:#{invoice_id}")

      progress = DiscourseBtcpay.get_payment_progress(user_id)
      received = Array(progress && progress["payments"]).map { |p| p["value"] }.compact.join(", ")
      user = User.find_by(id: user_id)

      DiscourseBtcpay.notify_admin(
        :underpaid,
        invoice_id: invoice_id,
        username: user&.username || user_id,
        received: received.presence || I18n.t("discourse_btcpay.alerts.underpaid.partial")
      )
    end

    def handle_invoice_invalid(event)
      invoice_id = event["invoiceId"]
      user_id = resolve_user_id(event)
      return unless user_id

      DiscourseBtcpay.clear_payment_progress(user_id)

      BtcpaySubscriptionManager.new.mark_disputed(user_id: user_id, invoice_id: invoice_id)
    end
  end
end
