import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class BtcpaySubscriptionStatus extends Component {
  @tracked subscription = null;
  @tracked payments = [];
  @tracked portalUrl = null;
  @tracked error = null;
  @tracked loading = true;

  constructor() {
    super(...arguments);
    this.load();
  }

  async load() {
    try {
      const result = await ajax("/btcpay/subscription");
      this.subscription = result.subscription;
      this.payments = result.payments || [];
      this.portalUrl = result.portal_url;
    } catch (e) {
      this.error = extractError(e);
    } finally {
      this.loading = false;
    }
  }

  get statusClass() {
    return this.subscription ? `btcpay-status-${this.subscription.status}` : "";
  }

  <template>
    <div class="btcpay-user-billing">
      <h2>{{i18n "btcpay.billing.title"}}</h2>

      {{#if this.loading}}
        <p>{{i18n "btcpay.loading"}}</p>
      {{else if this.error}}
        <div class="btcpay-error alert alert-error">{{this.error}}</div>
      {{else if this.subscription}}
        <div class="btcpay-sub-card {{this.statusClass}}">
          <div class="btcpay-sub-info">
            <div class="btcpay-sub-row">
              <span class="label">{{i18n "btcpay.billing.plan"}}</span>
              <span class="value">{{this.subscription.plan_name}}</span>
            </div>
            <div class="btcpay-sub-row">
              <span class="label">{{i18n "btcpay.billing.status"}}</span>
              <span class="value btcpay-badge {{this.statusClass}}">
                {{i18n (concat "btcpay.status." this.subscription.status)}}
              </span>
            </div>
            {{#if this.subscription.period_end}}
              <div class="btcpay-sub-row">
                <span class="label">{{i18n "btcpay.billing.period_end"}}</span>
                <span class="value">{{this.subscription.period_end}}</span>
              </div>
            {{/if}}
          </div>

          {{#if this.portalUrl}}
            <a
              href={{this.portalUrl}}
              class="btn btn-default btcpay-portal-link"
              target="_blank"
              rel="noopener noreferrer"
            >
              {{i18n "btcpay.billing.manage"}}
            </a>
          {{/if}}
        </div>

        {{#if this.payments.length}}
          <h3>{{i18n "btcpay.billing.history"}}</h3>
          <table class="btcpay-payments-table">
            <thead>
              <tr>
                <th>{{i18n "btcpay.billing.col_date"}}</th>
                <th>{{i18n "btcpay.billing.col_amount"}}</th>
                <th>{{i18n "btcpay.billing.col_method"}}</th>
                <th>{{i18n "btcpay.billing.col_status"}}</th>
              </tr>
            </thead>
            <tbody>
              {{#each this.payments as |payment|}}
                <tr>
                  <td>{{payment.paid_at}}</td>
                  <td>{{payment.amount}} {{payment.currency}}</td>
                  <td>{{payment.payment_method}}</td>
                  <td>
                    <span class="btcpay-badge btcpay-status-{{payment.status}}">
                      {{payment.status}}
                    </span>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{/if}}
      {{else}}
        <p class="btcpay-no-sub">{{i18n "btcpay.billing.none"}}</p>
      {{/if}}
    </div>
  </template>
}
