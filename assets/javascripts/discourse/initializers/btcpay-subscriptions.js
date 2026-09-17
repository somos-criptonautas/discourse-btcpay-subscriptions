import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

export default {
  name: "btcpay-subscriptions",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.btcpay_enabled) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminSidebarSectionLink("plugins", {
        name: "btcpay",
        label: "btcpay.admin.title",
        route: "adminPlugins.btcpay",
        icon: "bitcoin-sign",
      });

      api.addCommunitySectionLink?.({
        name: "btcpay-subscribe",
        route: "btcpaySubscribe",
        title: i18n("btcpay.subscribe.title"),
        text: i18n("btcpay.subscribe.nav_label"),
        icon: "bitcoin-sign",
      });
    });
  },
};
