# frozen_string_literal: true

module DiscourseBtcpay
  # /tickets and /billing are Ember routes. Rails still needs a route for them
  # or a direct visit (or a refresh) 404s before Ember ever boots: check_xhr
  # turns a browser navigation into the app shell, while XHR gets plain JSON.
  class BtcpayPagesController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    # check_xhr turns a browser GET into the app shell before any normal
    # before_action runs, so the disabled check has to come first or a disabled
    # plugin would still serve the page.
    prepend_before_action :ensure_btcpay_enabled

    def index
      render json: success_json
    end

    private

    def ensure_btcpay_enabled
      raise Discourse::NotFound unless SiteSetting.btcpay_enabled
    end
  end
end
