import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat } from "@ember/helper";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

export default class BtcpaySubscriptionStatus extends Component {
  @service currentUser;

  @tracked subscription = null;
  @tracked payments = [];
  @tracked portalUrl = null;
  @tracked error = null;
  @tracked loading = true;

  constructor() {
    super(...arguments);
    if (this.currentUser) {
      this.load();
    } else {
      this.loading = false;
    }
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

  get phase() {
    return this.subscription?.phase;
  }

  get inTrial() {
    return this.phase === "Trial";
  }

  // Grace means BTCPay is still waiting for the renewal payment; access is
  // deliberately kept until the grace period ends.
  get inGrace() {
    return this.phase === "Grace";
  }

  get showsAutoRenewOff() {
    return this.subscription?.auto_renew === false;
  }

  <template>
    <div class="btcpay-user-billing">
      <h2>{{i18n "btcpay.billing.section_title"}}</h2>

      {{#if (not this.currentUser)}}
        <p class="btcpay-anon">{{i18n "btcpay.billing.login_required"}}</p>
      {{else if this.loading}}
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
            {{#if this.inTrial}}
              <div class="btcpay-sub-row btcpay-trial">
                <span class="label">{{i18n "btcpay.billing.trial"}}</span>
                <span class="value">
                  {{i18n
                    "btcpay.billing.trial_ends"
                    date=this.subscription.trial_end
                  }}
                </span>
              </div>
            {{/if}}

            {{#if this.inGrace}}
              <div class="btcpay-sub-row btcpay-grace">
                <span class="label">{{i18n "btcpay.billing.grace"}}</span>
                <span class="value">
                  {{i18n
                    "btcpay.billing.grace_ends"
                    date=this.subscription.grace_period_end
                  }}
                </span>
              </div>
            {{/if}}

            {{#if this.subscription.needs_upgrade}}
              <div class="btcpay-sub-row btcpay-needs-upgrade">
                <span class="value">{{i18n
                    "btcpay.billing.needs_upgrade"
                  }}</span>
              </div>
            {{/if}}

            {{#if this.subscription.next_plan_name}}
              <div class="btcpay-sub-row btcpay-next-plan">
                <span class="value">
                  {{i18n
                    "btcpay.billing.next_plan"
                    plan=this.subscription.next_plan_name
                    date=this.subscription.next_plan_at
                  }}
                </span>
              </div>
            {{/if}}

            {{#if this.showsAutoRenewOff}}
              <div class="btcpay-sub-row btcpay-no-renew">
                <span class="value">{{i18n
                    "btcpay.billing.auto_renew_off"
                  }}</span>
              </div>
            {{/if}}

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
