# frozen_string_literal: true

module DiscourseBtcpay
  # /tickets and /billing are Ember routes. Rails still needs a route for them
  # or a direct visit (or a refresh) 404s before Ember ever boots: check_xhr
  # turns a browser navigation into the app shell, while XHR gets plain JSON.
  class BtcpayPagesController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    def index
      render json: success_json
    end
  end
end
