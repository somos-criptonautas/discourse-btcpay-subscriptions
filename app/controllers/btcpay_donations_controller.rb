# frozen_string_literal: true

module DiscourseBtcpay
  # One-off donations through a BTCPay Point of Sale app. The POS is public,
  # so the only thing that must come from the server is the order id that
  # attributes the payment — otherwise a browser could credit anyone.
  class BtcpayDonationsController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    before_action :ensure_donations_enabled

    # POST /btcpay/donate
    # Body: { amount: "10", payment_method: "card" (optional) }
    def create
      ensure_logged_in

      RateLimiter.new(current_user, "btcpay-donate", 5, 1.minute).performed!

      amount = params.require(:amount).to_f.round(2)
      minimum = SiteSetting.btcpay_donation_min.to_f

      if amount < minimum
        return (
          render json: {
                   error:
                     I18n.t(
                       "discourse_btcpay.errors.donation_too_small",
                       minimum: minimum,
                       currency: SiteSetting.btcpay_donation_currency
                     )
                 },
                 status: :unprocessable_entity
        )
      end

      api = BtcpayApi.new
      result =
        api.create_pos_invoice(
          app_id: SiteSetting.btcpay_pos_app_id,
          amount: amount,
          order_id: DiscourseBtcpay.donation_order_id(current_user.id),
          email: (current_user.email if SiteSetting.btcpay_send_email),
          redirect_url: "#{Discourse.base_url}#{SiteSetting.btcpay_redirect_after_checkout}"
        )

      invoice_id = result["invoiceId"] || result["id"]

      unless invoice_id
        Rails.logger.error("DiscourseBtcpay: POS returned no invoice: #{result.inspect}")
        return render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") },
                      status: :bad_gateway
      end

      card = card_payment?

      # A card donation is the same POS invoice opened on the Stripe method, so
      # it reaches the same webhook and is credited like any other. The overlay
      # cannot pick a method, hence no modal for card.
      render json: {
        invoice_id: invoice_id,
        checkout_url:
          api.invoice_url(invoice_id, card ? DiscourseBtcpay::STRIPE_PAYMENT_METHOD : nil),
        modal_url: card ? nil : "#{SiteSetting.btcpay_server_url.chomp("/")}/modal/btcpay.js"
      }
    rescue RateLimiter::LimitExceeded
      render json: { error: I18n.t("discourse_btcpay.errors.rate_limited") },
             status: :too_many_requests
    rescue BtcpayApi::ApiError => e
      Rails.logger.error("DiscourseBtcpay: Donation invoice failed: #{e.message}")
      render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") },
             status: :bad_gateway
    end

    # GET /btcpay/donations
    # Public: this is what drives a fundraising bar.
    def index
      donors =
        DiscourseBtcpay
          .each_donor
          .map { |user_id, data| [user_id, data] }
          .sort_by { |_user_id, data| -data["total"].to_f }

      supporters =
        donors
          .first(20)
          .filter_map do |user_id, data|
            user = User.find_by(id: user_id)
            next unless user

            {
              username: user.username,
              avatar_template: user.avatar_template,
              amount: data["total"].to_f.round(2),
              count: data["count"].to_i
            }
          end

      render json: {
        currency: SiteSetting.btcpay_donation_currency,
        total: donors.sum { |_user_id, data| data["total"].to_f }.round(2),
        count: donors.sum { |_user_id, data| data["count"].to_i },
        supporters: supporters
      }
    end

    private

    def card_payment?
      SiteSetting.btcpay_card_payments && params[:payment_method] == "card"
    end

    def ensure_donations_enabled
      unless SiteSetting.btcpay_enabled && SiteSetting.btcpay_donations_enabled
        return render json: { error: I18n.t("discourse_btcpay.errors.not_enabled") },
                      status: :service_unavailable
      end

      if action_name == "create" && SiteSetting.btcpay_pos_app_id.blank?
        render json: { error: I18n.t("discourse_btcpay.errors.missing_config") },
               status: :service_unavailable
      end
    end
  end
end
