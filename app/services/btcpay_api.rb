# frozen_string_literal: true

module DiscourseBtcpay
  # Greenfield client for BTCPay's subscriptions API (BTCPay 2.3+).
  #
  # Shape of that API, since it is not obvious: plans belong to an *offering*,
  # subscribers are addressed per offering by a CustomerSelector (customer id,
  # email, or Key:Value identity), and checkout/portal are store-agnostic
  # top-level endpoints that take the store id in the body.
  class BtcpayApi
    class ApiError < StandardError; end
    class NotFound < ApiError; end

    def initialize
      @base_url = SiteSetting.btcpay_server_url.to_s.chomp("/")
      @api_key = SiteSetting.btcpay_api_key
      @store_id = SiteSetting.btcpay_store_id
      @offering_id = SiteSetting.btcpay_offering_id
    end

    def configured?
      [@base_url, @api_key, @store_id, @offering_id].all?(&:present?)
    end

    # The offering carries its plans inline
    def offering
      get("/api/v1/stores/#{@store_id}/offerings/#{@offering_id}")
    end

    def plans
      Array(offering["plans"])
    end

    def plan(plan_id)
      get("/api/v1/stores/#{@store_id}/offerings/#{@offering_id}/plans/#{plan_id}")
    end

    # Returns a PlanCheckoutModel: { url, invoiceId, subscriber, ... }
    # on_pay_behavior: "HardMigration" starts the new plan immediately and
    # refunds the unused part of the old one — that is what a tier upgrade is.
    def create_plan_checkout(
      plan_id:,
      customer_selector: nil,
      subscriber_metadata: {},
      invoice_metadata: {},
      success_redirect_link: nil,
      on_pay_behavior: nil,
      new_subscriber_email: nil
    )
      body = {
        storeId: @store_id,
        offeringId: @offering_id,
        planId: plan_id,
        invoiceMetadata: invoice_metadata
      }
      body[:onPayBehavior] = on_pay_behavior if on_pay_behavior.present?
      body[:customerSelector] = customer_selector if customer_selector.present?
      # Without this BTCPay stops to ask the payer for an email address
      body[:newSubscriberEmail] = new_subscriber_email if new_subscriber_email.present?
      body[:newSubscriberMetadata] = subscriber_metadata if subscriber_metadata.present?
      body[:successRedirectLink] = success_redirect_link if success_redirect_link.present?

      post("/api/v1/plan-checkout", body)
    end

    # Continues a checkout: BTCPay either assigns the invoice to pay
    # (invoiceId) or starts the plan outright when nothing is due
    # (planStarted). Skipping this leaves the payer on BTCPay's own
    # "Subscribe" page for a second click.
    def proceed_plan_checkout(checkout_id)
      post("/api/v1/plan-checkout/#{CGI.escape(checkout_id.to_s)}", {})
    end

    # The POS app is a public MVC endpoint, not Greenfield: form-encoded in,
    # JSON out, no API key. order_id is what ties the invoice back to a user.
    def create_pos_invoice(app_id:, amount:, order_id:, email: nil, redirect_url: nil)
      uri = URI("#{@base_url}/apps/#{CGI.escape(app_id.to_s)}/pos")
      request = Net::HTTP::Post.new(uri)
      form = { "amount" => amount.to_s, "orderId" => order_id }
      form["email"] = email if email.present?
      form["redirectUrl"] = redirect_url if redirect_url.present?
      request.set_form_data(form)
      request["Accept"] = "application/json"

      result = execute(uri, request, authenticate: false, json_body: false)
      raise ApiError, result["error"] if result.is_a?(Hash) && result["error"].present?

      result
    end

    # payment_method_id opens the checkout on that method, e.g. "STRIPE"
    def invoice_url(invoice_id, payment_method_id = nil)
      url = "#{@base_url}/i/#{invoice_id}"
      payment_method_id.present? ? "#{url}/#{CGI.escape(payment_method_id)}" : url
    end

    # Returns a SubscriberModel: { isActive, isSuspended, phase, periodEnd, plan, customer, ... }
    def subscriber(customer_selector)
      get(
        "/api/v1/stores/#{@store_id}/offerings/#{@offering_id}/subscribers/#{CGI.escape(customer_selector.to_s)}"
      )
    end

    # A short-lived URL where the subscriber manages their own subscription
    def portal_session(customer_selector)
      post(
        "/api/v1/subscriber-portal",
        { storeId: @store_id, offeringId: @offering_id, customerSelector: customer_selector }
      )
    end

    def invoice(invoice_id)
      get("/api/v1/stores/#{@store_id}/invoices/#{CGI.escape(invoice_id.to_s)}")
    end

    def invoice_payment_methods(invoice_id)
      get("/api/v1/stores/#{@store_id}/invoices/#{CGI.escape(invoice_id.to_s)}/payment-methods")
    end

    # Which crypto actually paid an invoice ("BTC", "XMR", "BTC-LightningNetwork", …).
    # nil when nothing is paid yet or BTCPay does not say.
    def settled_payment_method(invoice_id)
      methods = invoice_payment_methods(invoice_id)
      return nil unless methods.is_a?(Array)

      paid =
        methods.find do |m|
          m["paymentMethodPaid"].to_f > 0 || m["totalPaid"].to_f > 0 || m["payments"].present?
        end

      paid && (paid["paymentMethodId"] || paid["paymentMethod"] || paid["cryptoCode"])
    end

    def server_info
      get("/api/v1/server/info")
    end

    private

    def get(path, params = {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      execute(uri, Net::HTTP::Get.new(uri))
    end

    def post(path, body = {})
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request.body = body.to_json
      execute(uri, request)
    end

    def execute(uri, request, authenticate: true, json_body: true)
      request["Content-Type"] = "application/json" if json_body
      request["Authorization"] = "token #{@api_key}" if authenticate

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15

      response = http.request(request)

      case response.code.to_i
      when 200..299
        body = response.body
        body.present? ? JSON.parse(body) : {}
      when 401, 403
        raise ApiError, "BTCPay authentication failed. Check your API key and its permissions."
      when 404
        raise NotFound, "BTCPay resource not found: #{uri.path}"
      else
        raise ApiError, "BTCPay API error #{response.code}: #{response.body&.truncate(200)}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise ApiError, "BTCPay connection timeout: #{e.message}"
    rescue JSON::ParserError => e
      raise ApiError, "Invalid JSON response from BTCPay: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ApiError, "Cannot connect to BTCPay Server at #{@base_url}: #{e.message}"
    rescue URI::InvalidURIError, ArgumentError => e
      # e.g. btcpay_server_url is blank or missing its scheme
      raise ApiError, "Invalid BTCPay Server URL #{@base_url.inspect}: #{e.message}"
    end
  end
end
