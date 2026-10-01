import { withPluginApi } from "discourse/lib/plugin-api";
import BtcpayCheckout from "../components/btcpay-checkout";
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
