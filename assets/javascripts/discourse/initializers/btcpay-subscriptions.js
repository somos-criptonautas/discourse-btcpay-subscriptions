import { withPluginApi } from "discourse/lib/plugin-api";
import { btcpayText } from "../lib/btcpay-text";

// Must match the plugin's directory name — that is the id the admin plugin
// list and the adminPlugins.show route use.
const PLUGIN_ID = "discourse-btcpay-subscriptions";

export default {
  name: "btcpay-subscriptions",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.btcpay_enabled) {
      return;
    }

    const navLabel = btcpayText(
      siteSettings,
      "btcpay_nav_label",
      "btcpay.tickets.nav_label"
    );

    withPluginApi((api) => {
      api.setAdminPluginIcon?.(PLUGIN_ID, "bitcoin-sign");
      api.addAdminPluginConfigurationNav?.(PLUGIN_ID, [
        {
          label: "btcpay.admin.title",
          route: "adminPlugins.show.btcpay",
        },
      ]);

      api.addCommunitySectionLink?.({
        name: "btcpay-tickets",
        route: "btcpayTickets",
        title: navLabel,
        text: navLabel,
        icon: "ticket",
      });
    });
  },
};
