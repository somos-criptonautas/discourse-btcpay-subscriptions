import { withPluginApi } from "discourse/lib/plugin-api";
import { btcpayText } from "../lib/btcpay-text";

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
      api.addAdminSidebarSectionLink("plugins", {
        name: "btcpay",
        label: "btcpay.admin.title",
        route: "adminPlugins.btcpay",
        icon: "bitcoin-sign",
      });

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
