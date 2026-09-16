import { withPluginApi } from "discourse/lib/plugin-api";

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
    });
  },
};
