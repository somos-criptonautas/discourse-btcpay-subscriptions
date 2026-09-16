import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { eq, not, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

export default class BtcpayButton extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked plans = [];
  @tracked loading = false;
  @tracked error = null;
  @tracked selectedPlan = null;

  constructor() {
    super(...arguments);
    if (this.isVisible) {
      this.loadPlans();
    }
  }

  async loadPlans() {
    try {
      const result = await ajax("/btcpay/plans");
      this.plans = result.plans || [];
      if (this.plans.length === 1) {
        this.selectedPlan = this.plans[0].plan_id;
      }
    } catch (e) {
      this.error = extractError(e);
    }
  }

  @action
  selectPlan(planId) {
    this.selectedPlan = planId;
  }

  @action
  async checkout() {
    if (!this.selectedPlan) {
      return;
    }

    this.loading = true;
    this.error = null;

    try {
      const result = await ajax("/btcpay/checkout", {
        type: "POST",
        data: { plan_id: this.selectedPlan },
      });

      if (result.checkout_url) {
        window.location.href = result.checkout_url;
      } else {
        this.error = i18n("btcpay.checkout.failed");
      }
    } catch (e) {
      this.error = extractError(e, i18n("btcpay.checkout.failed"));
    } finally {
      this.loading = false;
    }
  }

  get buttonLabel() {
    return (
      this.siteSettings.btcpay_button_label ||
      i18n("btcpay.checkout.default_label")
    );
  }

  get isVisible() {
    return this.siteSettings.btcpay_enabled && this.currentUser;
  }

  <template>
    {{#if this.isVisible}}
      <div class="btcpay-checkout-section">
        <h3 class="btcpay-heading">{{this.buttonLabel}}</h3>

        {{#if this.plans.length}}
          <div class="btcpay-plans">
            {{#each this.plans as |plan|}}
              <label
                class="btcpay-plan-option
                  {{if (eq this.selectedPlan plan.plan_id) 'selected'}}"
              >
                <input
                  type="radio"
                  name="btcpay_plan"
                  value={{plan.plan_id}}
                  checked={{eq this.selectedPlan plan.plan_id}}
                  {{on "change" (fn this.selectPlan plan.plan_id)}}
                />
                <span class="btcpay-plan-label">{{plan.label}}</span>
                {{#if plan.price}}
                  <span class="btcpay-plan-price">
                    {{plan.price}}
                    {{plan.currency}}
                    {{#if plan.interval}}/ {{plan.interval}}{{/if}}
                  </span>
                {{/if}}
              </label>
            {{/each}}
          </div>

          <button
            class="btn btn-primary btcpay-checkout-btn"
            disabled={{or this.loading (not this.selectedPlan)}}
            type="button"
            {{on "click" this.checkout}}
          >
            {{if
              this.loading
              (i18n "btcpay.checkout.processing")
              this.buttonLabel
            }}
          </button>
        {{else}}
          <p class="btcpay-no-plans">{{i18n "btcpay.checkout.no_plans"}}</p>
        {{/if}}

        {{#if this.error}}
          <div class="btcpay-error alert alert-error">{{this.error}}</div>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
