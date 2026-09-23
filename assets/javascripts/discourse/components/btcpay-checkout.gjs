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
import { btcpayText } from "../lib/btcpay-text";

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
  @tracked currentPlanId = null;
  @tracked currentPrice = null;
  @tracked progress = null;

  pollTimer = null;
  pollCount = 0;

  constructor() {
    super(...arguments);
    if (this.isVisible) {
      this.load();
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
    return btcpayText(
      this.siteSettings,
      "btcpay_button_label",
      "btcpay.checkout.default_label"
    );
  }

  // Each plan carries how it relates to what the user already has
  get offers() {
    return this.plans.map((plan) => {
      const isCurrent = plan.plan_id === this.currentPlanId;
      const cheaper =
        this.currentPrice !== null &&
        parseFloat(plan.price) < parseFloat(this.currentPrice);

      return {
        ...plan,
        isCurrent,
        // Downgrades are a later feature; until then they are not selectable
        isBlocked: !isCurrent && cheaper,
        isUpgrade:
          !isCurrent &&
          this.currentPlanId &&
          parseFloat(plan.price) > parseFloat(this.currentPrice),
      };
    });
  }

  get selectable() {
    return this.offers.filter((o) => !o.isCurrent && !o.isBlocked);
  }

  async load() {
    await Promise.all([this.loadPlans(), this.loadCurrent()]);

    if (!this.selectedPlan && this.selectable.length === 1) {
      this.selectedPlan = this.selectable[0].plan_id;
    }
  }

  async loadPlans() {
    try {
      const result = await ajax("/btcpay/plans");
      this.plans = result.plans || [];
    } catch (e) {
      this.error = extractError(e);
    }
  }

  async loadCurrent() {
    try {
      const result = await ajax("/btcpay/subscription");
      this.progress = result.payment_progress;

      if (result.subscription?.status === "active") {
        this.currentPlanId = result.subscription.plan_id;
        this.currentPrice =
          this.plans.find((p) => p.plan_id === this.currentPlanId)?.price ??
          null;
      }
    } catch {
      // Not fatal — the user can still start a checkout.
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
      this.progress = result.payment_progress;

      if (result.subscription?.status === "active") {
        this.settled = true;
        this.progress = null;
        this.currentPlanId = result.subscription.plan_id;
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
        {{#if this.settled}}
          <div class="btcpay-settled alert alert-success">
            {{i18n "btcpay.checkout.settled"}}
          </div>
        {{/if}}

        {{#if this.progress}}
          <div class="btcpay-progress alert alert-info">
            <p class="btcpay-progress-headline">
              {{i18n "btcpay.checkout.waiting_payment"}}
            </p>
            <ul class="btcpay-progress-list">
              {{#each this.progress.payments as |payment|}}
                <li class={{if payment.settled "settled" "pending"}}>
                  {{i18n
                    "btcpay.checkout.received"
                    value=payment.value
                    method=payment.method
                  }}
                  —
                  {{if
                    payment.settled
                    (i18n "btcpay.checkout.confirmed")
                    (i18n "btcpay.checkout.unconfirmed")
                  }}
                </li>
              {{/each}}
            </ul>
          </div>
        {{/if}}

        {{#if this.offers.length}}
          <fieldset class="btcpay-plans">
            <legend class="btcpay-plans__legend">
              {{i18n "btcpay.checkout.choose_plan"}}
            </legend>

            {{#each this.offers as |plan|}}
              <label
                class="btcpay-plan
                  {{if (eq this.selectedPlan plan.plan_id) 'is-selected'}}
                  {{if plan.isCurrent 'is-current'}}
                  {{if plan.isBlocked 'is-blocked'}}"
              >
                <input
                  type="radio"
                  class="btcpay-plan__radio"
                  name="btcpay_plan"
                  value={{plan.plan_id}}
                  checked={{eq this.selectedPlan plan.plan_id}}
                  disabled={{or plan.isCurrent plan.isBlocked}}
                  {{on "change" (fn this.selectPlan plan.plan_id)}}
                />

                <span class="btcpay-plan__body">
                  <span class="btcpay-plan__header">
                    <span class="btcpay-plan__name">{{plan.label}}</span>

                    {{#if plan.isCurrent}}
                      <span class="btcpay-plan__badge --current">
                        {{i18n "btcpay.checkout.current_plan"}}
                      </span>
                    {{else if plan.isUpgrade}}
                      <span class="btcpay-plan__badge --upgrade">
                        {{i18n "btcpay.checkout.upgrade"}}
                      </span>
                    {{/if}}
                  </span>

                  {{#if plan.price}}
                    <span class="btcpay-plan__price">
                      <span class="btcpay-plan__amount">
                        {{plan.price}}
                        {{plan.currency}}
                      </span>
                      {{#if plan.interval}}
                        <span class="btcpay-plan__interval">
                          /
                          {{plan.interval}}
                        </span>
                      {{/if}}
                    </span>
                  {{/if}}

                  {{#if plan.description}}
                    <span class="btcpay-plan__description">
                      {{plan.description}}
                    </span>
                  {{/if}}

                  {{#if plan.trial_days}}
                    <span class="btcpay-plan__trial">
                      {{i18n
                        "btcpay.checkout.trial_days"
                        count=plan.trial_days
                      }}
                    </span>
                  {{/if}}

                  {{#if plan.isBlocked}}
                    <span class="btcpay-plan__note">
                      {{i18n "btcpay.checkout.downgrade_unavailable"}}
                    </span>
                  {{/if}}
                </span>
              </label>
            {{/each}}
          </fieldset>

          <button
            type="button"
            class="btn btn-primary btn-large btcpay-checkout-btn"
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
