import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default class BtcpayBillingLink extends Component {
  @service siteSettings;
  @service currentUser;

  // Only on your own profile — /billing always shows the viewer's own data.
  get isVisible() {
    return (
      this.siteSettings.btcpay_enabled &&
      this.currentUser?.id === this.args.outletArgs?.model?.id
    );
  }

  <template>
    {{#if this.isVisible}}
      <li class="btcpay-billing-nav">
        <LinkTo @route="btcpayBilling">
          {{icon "credit-card"}}
          <span>{{i18n "btcpay.billing.nav_label"}}</span>
        </LinkTo>
      </li>
    {{/if}}
  </template>
}
