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

    const navLabel = btcpayText(
      siteSettings,
      "btcpay_nav_label",
      "btcpay.tickets.nav_label"
    );

    withPluginApi((api) => {
      api.setAdminPluginIcon?.(PLUGIN_ID, "bitcoin-sign");

      api.addCommunitySectionLink?.({
        name: "btcpay-tickets",
        route: "btcpayTickets",
        title: navLabel,
        text: navLabel,
        icon: "ph-dt-ticket",
      });

      // [wrap=btcpay-plans] in a post renders the plan picker inline. The
      // donations theme component owns the donate-* wraps, so the names never
      // collide and neither side has to know about the other.
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
