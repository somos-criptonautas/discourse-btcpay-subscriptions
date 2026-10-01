import { withPluginApi } from "discourse/lib/plugin-api";
import BtcpayCheckout from "../components/btcpay-checkout";
import { btcpayText } from "../lib/btcpay-text";
import { PLUGIN_ID } from "../lib/plugin-id";

export default {
  name: "btcpay-subscriptions",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.btcpay_enabled) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon?.(PLUGIN_ID, "bitcoin-sign");

      // With `sidebar_user_navigation` on, the profile nav becomes a sidebar
      // panel that cannot read plugin outlets, so the tab has to be registered
      // here as well as in the user-main-nav connector. Core drops the link by
      // itself when the route is missing, and the call is optional because the
      // panel only exists on newer cores.
      api.addUserNavSidebarLink?.("profile", {
        name: "btcpay-billing",
        route: "user.billing",
        icon: "ticket",
        label: "btcpay.billing.nav_label",
        text: ({ siteSettings: settings }) =>
          btcpayText(settings, "btcpay_nav_label", "btcpay.billing.nav_label"),
        // The tab always shows the viewer's own billing.
        displayed: ({ user, currentUser }) => currentUser?.id === user?.id,
      });

      // [wrap=btcpay-plans] in a post renders the plan picker inline — which is
      // how /tickets is linked, now that nothing is forced into the sidebar.
      // The donations theme component owns the donate-* wraps, so the names
      // never collide and neither side has to know about the other.
      api.decorateCookedElement((element, helper) => {
        // No renderGlimmer outside a real post (composer preview, digests).
        if (!helper) {
          return;
        }

        element
          .querySelectorAll('[data-wrap="btcpay-plans"]')
          .forEach((target) => {
            target.classList.add("btcpay-post-embed");
            target.replaceChildren();
            helper.renderGlimmer(target, BtcpayCheckout);
          });
      });
    });
  },
};
