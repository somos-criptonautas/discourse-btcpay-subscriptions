import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import icon from "discourse/helpers/d-icon";
import { btcpayText } from "../../lib/btcpay-text";

export default class BtcpayBillingLink extends Component {
  @service siteSettings;
  @service currentUser;

  get label() {
    return btcpayText(
      this.siteSettings,
      "btcpay_nav_label",
      "btcpay.billing.nav_label"
    );
  }

  // Only on your own profile — the tab always shows the viewer's own data.
  get isVisible() {
    return (
      this.siteSettings.btcpay_enabled &&
      this.currentUser?.id === this.args.outletArgs?.model?.id
    );
  }

  <template>
    {{#if this.isVisible}}
      <li class="btcpay-billing-nav">
        <LinkTo @route="user.billing">
          {{icon "ticket"}}
          <span>{{this.label}}</span>
        </LinkTo>
      </li>
    {{/if}}
  </template>
}
