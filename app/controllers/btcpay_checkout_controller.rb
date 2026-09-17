# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayCheckoutController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_btcpay_configured

    PLANS_CACHE_KEY = "btcpay_remote_plans"
    PLANS_CACHE_TTL = 10.minutes

    # POST /btcpay/checkout
    # Body: { plan_id: "xxx" }
    def create
      RateLimiter.new(current_user, "btcpay-checkout", 5, 1.minute).performed!
      RateLimiter.new(current_user, "btcpay-checkout-hourly", 20, 1.hour).performed!

      plan_id = params.require(:plan_id)

      manager = BtcpaySubscriptionManager.new
      unless manager.group_for_plan(plan_id)
        return render json: { error: I18n.t("discourse_btcpay.errors.plan_not_found") }, status: :not_found
      end

      existing = DiscourseBtcpay.get_subscription(current_user.id)

      change = plan_change(existing, plan_id)
      if change == :downgrade
        return render json: {
          error: I18n.t("discourse_btcpay.errors.downgrade_unsupported")
        }, status: :unprocessable_entity
      end

      metadata = {
        discourse_user_id: current_user.id.to_s,
        discourse_username: current_user.username,
        discourse_plan_id: plan_id
      }

      result =
        BtcpayApi.new.create_plan_checkout(
          plan_id: plan_id,
          # A returning subscriber keeps their BTCPay customer record
          customer_selector: existing && existing["customer_id"],
          subscriber_metadata: metadata,
          invoice_metadata: metadata,
          success_redirect_link: "#{Discourse.base_url}#{SiteSetting.btcpay_redirect_after_checkout}",
          # An upgrade should take effect now, refunding the unused remainder
          on_pay_behavior: change == :upgrade ? "HardMigration" : nil
        )

      checkout_url = result["url"] || result["redirectUrl"]

      unless checkout_url
        Rails.logger.error("DiscourseBtcpay: No checkout URL returned: #{result.inspect}")
        return render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") }, status: :bad_gateway
      end

      remember_customer(result)

      # invoice_id + modal_url let the client open BTCPay's overlay; the
      # checkout_url is the fallback when the modal script can't load.
      render json: {
        checkout_url: checkout_url,
        invoice_id: result["invoiceId"],
        modal_url: "#{SiteSetting.btcpay_server_url.chomp("/")}/modal/btcpay.js"
      }
    rescue RateLimiter::LimitExceeded
      render json: { error: I18n.t("discourse_btcpay.errors.rate_limited") }, status: :too_many_requests
    rescue BtcpayApi::ApiError => e
      Rails.logger.error("DiscourseBtcpay: Checkout creation failed: #{e.message}")
      render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") }, status: :bad_gateway
    end

    # GET /btcpay/subscription
    def status
      sub = DiscourseBtcpay.get_subscription(current_user.id)
      payments = DiscourseBtcpay.get_payments(current_user.id)

      progress = DiscourseBtcpay.get_payment_progress(current_user.id)

      if sub
        render json: {
          subscription: sub,
          payments: payments.last(20),
          payment_progress: progress,
          portal_url: portal_url(sub["customer_id"])
        }
      else
        render json: {
          subscription: nil,
          payments: [],
          payment_progress: progress,
          portal_url: nil
        }
      end
    end

    # GET /btcpay/plans
    def plans
      remote = remote_plans

      plans =
        DiscourseBtcpay.plan_mappings.map do |mapping|
          plan = mapping.dup
          details = remote.find { |p| p["id"] == plan["plan_id"] }
          next plan unless details

          # BTCPay is the source of truth for price; the mapping only names it.
          plan["label"] = plan["label"].presence || details["name"]
          plan["price"] = details["price"]
          plan["currency"] = details["currency"]
          plan["interval"] = details["recurringType"]
          plan["description"] = details["description"]
          plan["trial_days"] = details["trialDays"]
          plan
        end

      render json: { plans: plans }
    end

    private

    # :new, :renewal, :upgrade or :downgrade, decided on BTCPay's prices so a
    # crafted request cannot buy a cheaper tier as if it were an upgrade.
    def plan_change(existing, plan_id)
      return :new unless existing && existing["status"] == "active"

      current_plan_id = existing["plan_id"]
      return :renewal if current_plan_id == plan_id

      prices = remote_plans.index_by { |p| p["id"] }
      current = prices[current_plan_id]
      wanted = prices[plan_id]
      return :new if current.nil? || wanted.nil?

      wanted["price"].to_f > current["price"].to_f ? :upgrade : :downgrade
    end

    # Prices come from BTCPay, cached so a popular page does not hammer it.
    def remote_plans
      cached =
        Discourse
          .cache
          .fetch(PLANS_CACHE_KEY, expires_in: PLANS_CACHE_TTL) do
            BtcpayApi.new.plans
          rescue BtcpayApi::ApiError => e
            Rails.logger.warn("DiscourseBtcpay: Could not fetch plans from BTCPay: #{e.message}")
            nil
          end

      cached.is_a?(Array) ? cached : []
    end

    # BTCPay may have created the customer during checkout; hold on to the id
    # so later lookups and renewals address the same subscriber.
    def remember_customer(result)
      customer_id = result.dig("subscriber", "customer", "id")
      return if customer_id.blank?

      sub = DiscourseBtcpay.get_subscription(current_user.id) || {}
      return if sub["customer_id"] == customer_id

      DiscourseBtcpay.store_subscription(
        current_user.id,
        sub.merge("customer_id" => customer_id, "updated_at" => Time.now.iso8601)
      )
    end

    def ensure_btcpay_configured
      unless SiteSetting.btcpay_enabled
        return render json: { error: I18n.t("discourse_btcpay.errors.not_enabled") }, status: :service_unavailable
      end

      unless BtcpayApi.new.configured?
        render json: { error: I18n.t("discourse_btcpay.errors.missing_config") },
               status: :service_unavailable
      end
    end

    # A real portal session, not a guessed URL
    def portal_url(customer_id)
      return nil if customer_id.blank?

      BtcpayApi.new.portal_session(customer_id)["url"]
    rescue BtcpayApi::ApiError => e
      Rails.logger.warn("DiscourseBtcpay: Could not create portal session: #{e.message}")
      nil
    end
  end
end
