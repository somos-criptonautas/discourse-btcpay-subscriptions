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

// The modal only tells us "closed", never "settled" — BTCPay decides that
// asynchronously once the payment confirms. So we ask our own endpoint.
const POLL_INTERVAL_MS = 10_000;
const POLL_LIMIT = 60;

let modalScript = null;

function loadModalScript(url) {
  modalScript ||= new Promise((resolve, reject) => {
    // Injected from already-trusted code so strict-dynamic allows it; a
    // blocked or missing script rejects and we fall back to a redirect.
    const el = document.createElement("script");
    el.src = url;
    el.async = true;
    el.onload = resolve;
    el.onerror = () => {
      modalScript = null;
      reject(new Error("btcpay.js failed to load"));
    };
    document.head.appendChild(el);
  });

  return modalScript;
}

export default class BtcpayCheckout extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked plans = [];
  @tracked loading = false;
  @tracked error = null;
  @tracked selectedPlan = null;
  @tracked settled = false;

  pollTimer = null;
  pollCount = 0;

  constructor() {
    super(...arguments);
    if (this.isVisible) {
      this.loadPlans();
    }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.stopPolling();
  }

  get isVisible() {
    return this.siteSettings.btcpay_enabled && this.currentUser;
  }

  get buttonLabel() {
    return (
      this.siteSettings.btcpay_button_label ||
      i18n("btcpay.checkout.default_label")
    );
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

      if (await this.openModal(result)) {
        return;
      }

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

  async openModal(result) {
    if (!result.invoice_id || !result.modal_url) {
      return false;
    }

    try {
      await loadModalScript(result.modal_url);
      if (!window.btcpay?.showInvoice) {
        return false;
      }
      window.btcpay.showInvoice(result.invoice_id);
      this.startPolling();
      return true;
    } catch {
      return false;
    }
  }

  startPolling() {
    this.stopPolling();
    this.pollCount = 0;
    this.pollTimer = setInterval(() => this.pollStatus(), POLL_INTERVAL_MS);
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  async pollStatus() {
    this.pollCount++;
    if (this.pollCount > POLL_LIMIT) {
      this.stopPolling();
      return;
    }

    try {
      const result = await ajax("/btcpay/subscription");
      if (result.subscription?.status === "active") {
        this.settled = true;
        this.stopPolling();
        this.args.onSettled?.();
      }
    } catch {
      // A failed poll is not a failed payment; the reconcile job is the net.
    }
  }

  <template>
    {{#if this.isVisible}}
      <div class="btcpay-checkout-section">
        <h3 class="btcpay-heading">{{this.buttonLabel}}</h3>

        {{#if this.settled}}
          <div class="btcpay-settled alert alert-success">
            {{i18n "btcpay.checkout.settled"}}
          </div>
        {{/if}}

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
            type="button"
            class="btn btn-primary btcpay-checkout-btn"
            disabled={{or this.loading (not this.selectedPlan)}}
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
