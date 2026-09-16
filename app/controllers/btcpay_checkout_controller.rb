# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayCheckoutController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    before_action :ensure_logged_in, except: []
    before_action :ensure_btcpay_configured

    # POST /btcpay/checkout
    # Body: { plan_id: "xxx" }
    def create
      RateLimiter.new(current_user, "btcpay-checkout", 5, 1.minute).performed!
      RateLimiter.new(current_user, "btcpay-checkout-hourly", 20, 1.hour).performed!

      plan_id = params.require(:plan_id)

      manager = BtcpaySubscriptionManager.new
      group_name = manager.group_for_plan(plan_id)

      unless group_name
        return render json: { error: I18n.t("discourse_btcpay.errors.plan_not_found") }, status: :not_found
      end

      redirect_url = "#{Discourse.base_url}#{SiteSetting.btcpay_redirect_after_checkout}"

      api = BtcpayApi.new
      result = api.create_plan_checkout(
        plan_id: plan_id,
        metadata: {
          discourse_user_id: current_user.id.to_s,
          discourse_username: current_user.username,
          planId: plan_id
        },
        redirect_url: redirect_url
      )

      checkout_url = result["checkoutUrl"] || result["url"]

      unless checkout_url
        Rails.logger.error("DiscourseBtcpay: No checkout URL returned: #{result.inspect}")
        return render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") }, status: :bad_gateway
      end

      render json: { checkout_url: checkout_url }
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

      if sub
        render json: {
          subscription: sub,
          payments: payments.last(20),
          portal_url: btcpay_portal_url(sub["subscription_id"])
        }
      else
        render json: { subscription: nil, payments: [], portal_url: nil }
      end
    end

    # GET /btcpay/plans
    def plans
      parsed_plans = DiscourseBtcpay.plan_mappings.map(&:dup)

      # Enrich with BTCPay plan details if available
      begin
        api = BtcpayApi.new
        btcpay_plans = api.list_plans
        if btcpay_plans.is_a?(Array)
          parsed_plans.each do |plan|
            remote = btcpay_plans.find { |p| p["id"] == plan["plan_id"] }
            if remote
              plan["price"] = remote["amount"]
              plan["currency"] = remote["currency"]
              plan["interval"] = remote["period"]
            end
          end
        end
      rescue BtcpayApi::ApiError => e
        Rails.logger.warn("DiscourseBtcpay: Could not fetch plans from BTCPay: #{e.message}")
      end

      render json: { plans: parsed_plans }
    end

    private

    def ensure_btcpay_configured
      unless SiteSetting.btcpay_enabled
        return render json: { error: I18n.t("discourse_btcpay.errors.not_enabled") }, status: :service_unavailable
      end

      api = BtcpayApi.new
      unless api.configured?
        render json: { error: I18n.t("discourse_btcpay.errors.missing_config") },
               status: :service_unavailable
      end
    end

    def btcpay_portal_url(subscription_id)
      return nil unless subscription_id
      base = SiteSetting.btcpay_server_url.chomp("/")
      store_id = SiteSetting.btcpay_store_id
      "#{base}/stores/#{store_id}/subscriptions/#{subscription_id}"
    end
  end
end
