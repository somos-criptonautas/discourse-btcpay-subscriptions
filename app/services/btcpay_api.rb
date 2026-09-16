# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayApi
    class ApiError < StandardError; end

    def initialize
      @base_url = SiteSetting.btcpay_server_url.chomp("/")
      @api_key = SiteSetting.btcpay_api_key
      @store_id = SiteSetting.btcpay_store_id
    end

    def configured?
      @base_url.present? && @api_key.present? && @store_id.present?
    end

    # Create a plan checkout for a subscription
    # Returns { "checkoutUrl" => "https://..." }
    def create_plan_checkout(plan_id:, metadata: {}, redirect_url: nil)
      body = {
        metadata: metadata
      }
      body[:redirectUrl] = redirect_url if redirect_url

      post("/api/v1/stores/#{@store_id}/subscriptions/plans/#{plan_id}/checkouts", body)
    end

    # Get a specific subscription by ID
    def get_subscription(subscription_id)
      get("/api/v1/stores/#{@store_id}/subscriptions/#{subscription_id}")
    end

    # List all subscriptions for the store
    def list_subscriptions(status: nil)
      params = {}
      params[:status] = status if status
      get("/api/v1/stores/#{@store_id}/subscriptions", params)
    end

    # Get subscription plans (offerings)
    def list_plans
      get("/api/v1/stores/#{@store_id}/subscriptions/plans")
    end

    # Server metadata: version + per-chain sync status
    def server_info
      get("/api/v1/server/info")
    end

    # Get a specific invoice
    def get_invoice(invoice_id)
      get("/api/v1/stores/#{@store_id}/invoices/#{invoice_id}")
    end

    # Get invoice payment methods
    def get_invoice_payment_methods(invoice_id)
      get("/api/v1/stores/#{@store_id}/invoices/#{invoice_id}/payment-methods")
    end

    private

    def get(path, params = {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      request = Net::HTTP::Get.new(uri)
      execute(uri, request)
    end

    def post(path, body = {})
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request.body = body.to_json
      execute(uri, request)
    end

    def execute(uri, request)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "token #{@api_key}"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15

      response = http.request(request)

      case response.code.to_i
      when 200..299
        body = response.body
        body.present? ? JSON.parse(body) : {}
      when 401
        raise ApiError, "BTCPay authentication failed. Check your API key."
      when 404
        raise ApiError, "BTCPay resource not found: #{uri.path}"
      else
        raise ApiError, "BTCPay API error #{response.code}: #{response.body&.truncate(200)}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise ApiError, "BTCPay connection timeout: #{e.message}"
    rescue JSON::ParserError => e
      raise ApiError, "Invalid JSON response from BTCPay: #{e.message}"
    rescue Errno::ECONNREFUSED => e
      raise ApiError, "Cannot connect to BTCPay Server at #{@base_url}: #{e.message}"
    end
  end
end
