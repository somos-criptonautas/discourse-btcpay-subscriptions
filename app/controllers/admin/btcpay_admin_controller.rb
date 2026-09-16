# frozen_string_literal: true

module DiscourseBtcpay
  module Admin
    class BtcpayAdminController < ::Admin::AdminController
      requires_plugin DiscourseBtcpay::PLUGIN_NAME

      # GET /admin/plugins/btcpay
      def index
        api = BtcpayApi.new
        return render json: { configured: false } unless api.configured?

        info =
          begin
            api.server_info
          rescue BtcpayApi::ApiError => e
            Rails.logger.warn("DiscourseBtcpay: Could not fetch server info: #{e.message}")
            nil
          end

        btc = info && Array(info["syncStatus"]).find { |s| s["cryptoCode"] == "BTC" }

        render json: {
          configured: true,
          server_url: SiteSetting.btcpay_server_url,
          version: info && info["version"],
          fully_synched: info && info["fullySynched"],
          chain_height: btc && btc["chainHeight"],
          network: network_from_height(btc && btc["chainHeight"])
        }
      end

      # GET /admin/plugins/btcpay/subscriptions
      def subscriptions
        manager = BtcpaySubscriptionManager.new
        subs = manager.all_subscriptions

        # Filter by status if requested
        if params[:status].present?
          subs = subs.select { |s| s["status"] == params[:status] }
        end

        # Include payment history per user
        subs.each do |sub|
          sub["payments"] = DiscourseBtcpay.get_payments(sub["user_id"]) || []
        end

        render json: {
          subscriptions: subs,
          total: subs.size,
          active: subs.count { |s| s["status"] == "active" },
          expired: subs.count { |s| s["status"] == "expired" },
          cancelled: subs.count { |s| s["status"] == "cancelled" },
          pending: subs.count { |s| s["status"] == "pending" },
          disputed: subs.count { |s| s["status"] == "disputed" }
        }
      end

      # POST /admin/plugins/btcpay/sync
      # Manual trigger for reconciliation
      def sync
        Jobs.enqueue(:btcpay_reconcile, force: true)
        render json: { status: "queued" }
      end

      private

      # ponytail: Greenfield exposes no network field, so we read it off the
      # chain tip. Swap for the store's derivation-scheme prefix (xpub vs tpub)
      # if a band ever reports "unknown" on a real deployment.
      def network_from_height(height)
        return nil if height.nil?

        height = height.to_i

        if height >= 2_000_000
          "testnet"
        elsif height >= 400_000
          "mainnet"
        elsif height > 0
          "testnet/signet/regtest"
        else
          "unknown"
        end
      end
    end
  end
end
