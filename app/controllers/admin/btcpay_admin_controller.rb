# frozen_string_literal: true

module DiscourseBtcpay
  module Admin
    class BtcpayAdminController < ::Admin::AdminController
      requires_plugin DiscourseBtcpay::PLUGIN_NAME

      REQUIRED_SETTINGS = %w[
        btcpay_server_url
        btcpay_api_key
        btcpay_store_id
        btcpay_offering_id
      ].freeze

      # GET /admin/plugins/btcpay/status
      def index
        missing = REQUIRED_SETTINGS.select { |name| SiteSetting.get(name).blank? }

        if missing.any?
          # Naming the blank settings beats a bare "not configured" — the
          # offering id in particular is easy to miss.
          return render json: { configured: false, missing_settings: missing }
        end

        api = BtcpayApi.new

        info =
          begin
            api.server_info
          rescue BtcpayApi::ApiError => e
            Rails.logger.warn("DiscourseBtcpay: Could not fetch server info: #{e.message}")
            nil
          end

        sync = info ? Array(info["syncStatus"]) : []
        # BTC is the network yardstick when present; otherwise take whatever
        # chain BTCPay reports first.
        chain = sync.find { |s| s["cryptoCode"] == "BTC" } || sync.first

        render json: {
          configured: true,
          missing_settings: [],
          reachable: !info.nil?,
          server_url: SiteSetting.btcpay_server_url,
          offering_id: SiteSetting.btcpay_offering_id,
          version: info && info["version"],
          fully_synched: info && info["fullySynched"],
          chain_height: chain && chain["chainHeight"],
          network: network_from_height(chain && chain["chainHeight"]),
          cryptos: sync.filter_map { |s| s["cryptoCode"] }.uniq,
          plans: offering_plans,
          groups: assignable_groups,
          default_group: SiteSetting.btcpay_default_group,
          donations: donation_summary,
          badges: grantable_badges,
          donor_badge_id: DiscourseBtcpay.donor_badge_id
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

      # POST /admin/plugins/btcpay/plan_group
      # Body: { plan_id: "...", group_name: "premium" } — blank clears it
      def plan_group
        plan_id = params.require(:plan_id)
        group_name = params[:group_name].presence

        if group_name && !Group.exists?(name: group_name)
          return render json: { error: I18n.t("discourse_btcpay.errors.group_not_found") },
                        status: :unprocessable_entity
        end

        DiscourseBtcpay.set_plan_group(plan_id, group_name)

        render json: { plan_id: plan_id, group_name: group_name }
      end

      # POST /admin/plugins/btcpay/donor_badge
      # Body: { badge_id: 12 } — blank clears it
      def donor_badge
        badge_id = params[:badge_id].presence

        if badge_id && !Badge.exists?(id: badge_id, enabled: true)
          return render json: { error: I18n.t("discourse_btcpay.errors.badge_not_found") },
                        status: :unprocessable_entity
        end

        DiscourseBtcpay.set_donor_badge(badge_id)

        render json: { badge_id: DiscourseBtcpay.donor_badge_id }
      end

      # POST /admin/plugins/btcpay/sync
      # Manual trigger for reconciliation
      def sync
        Jobs.enqueue(:btcpay_reconcile, force: true)
        render json: { status: "queued" }
      end

      private

      # What BTCPay lists for the configured offering, and whether each plan
      # can actually grant anything here.
      def offering_plans
        DiscourseBtcpay.remote_plans.map do |plan|
          plan_id = plan["id"]
          group_name = DiscourseBtcpay.group_for_plan(plan_id, plan: plan)

          {
            id: plan_id,
            name: plan["name"],
            price: plan["price"],
            currency: plan["currency"],
            interval: plan["recurringType"],
            group_name: group_name,
            group_exists: group_name.present? && Group.exists?(name: group_name),
            assigned_group: DiscourseBtcpay.plan_groups[plan_id],
            source: DiscourseBtcpay.group_source(plan_id, plan: plan)
          }
        end
      end

      def donation_summary
        return nil unless SiteSetting.btcpay_donations_enabled

        donors = DiscourseBtcpay.each_donor.to_a

        {
          currency: SiteSetting.btcpay_donation_currency,
          total: donors.sum { |_user_id, data| data["total"].to_f }.round(2),
          count: donors.sum { |_user_id, data| data["count"].to_i },
          donors: donors.size
        }
      end

      def grantable_badges
        Badge.where(enabled: true).order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } }
      end

      # Groups an admin can hand out — automatic ones (trust levels, staff)
      # are not ours to grant.
      def assignable_groups
        Group.where(automatic: false).order(:name).pluck(:name)
      end

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
