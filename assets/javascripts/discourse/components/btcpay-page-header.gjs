import Component from "@glimmer/component";
import { service } from "@ember/service";
import { btcpayText } from "../lib/btcpay-text";

// Title and intro come from a site setting when the admin set one, and from
// the translations otherwise — so the default text stays localized.
export default class BtcpayPageHeader extends Component {
  @service siteSettings;

  get title() {
    return btcpayText(
      this.siteSettings,
      `btcpay_${this.args.page}_title`,
      `btcpay.${this.args.page}.title`
    );
  }

  get intro() {
    return btcpayText(
      this.siteSettings,
      `btcpay_${this.args.page}_intro`,
      `btcpay.${this.args.page}.intro`
    );
  }

  <template>
    <h1 class="btcpay-page-title">{{this.title}}</h1>
    {{#if this.intro}}
      <p class="btcpay-page-intro">{{this.intro}}</p>
    {{/if}}
  </template>
}
