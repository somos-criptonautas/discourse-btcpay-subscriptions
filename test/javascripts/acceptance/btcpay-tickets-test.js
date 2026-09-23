import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const PLANS = {
  plans: [
    {
      plan_id: "plan-1",
      label: "Premium",
      group_name: "premium",
      price: "10",
      currency: "USD",
      interval: "Monthly",
    },
    {
      plan_id: "plan-2",
      label: "VIP",
      group_name: "vip",
      price: "25",
      currency: "USD",
      interval: "Monthly",
    },
  ],
};

function noSubscription(helper) {
  return helper.response({
    subscription: null,
    payments: [],
    payment_progress: null,
    portal_url: null,
  });
}

acceptance("BTCPay | Tickets page", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () => noSubscription(helper));
  });

  test("lists every plan the offering returned", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-plan-option").exists({ count: 2 });
    assert.dom(".btcpay-plans").exists("plans are grouped in a fieldset");
    assert
      .dom(".btcpay-plan-option:first-of-type .btcpay-plan-price")
      .includesText("10 USD");
  });

  test("shows the checkout button", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-checkout-btn").exists();
  });
});

acceptance("BTCPay | Tickets page with a subscription", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response({
        subscription: {
          plan_id: "plan-2",
          plan_name: "VIP",
          status: "active",
          phase: "Normal",
        },
        payments: [],
        payment_progress: null,
        portal_url: null,
      })
    );
  });

  test("marks the current plan and blocks the cheaper one", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-plan-option.current").exists({ count: 1 });
    assert
      .dom(".btcpay-plan-option.blocked .btcpay-plan-badge.blocked")
      .exists("a downgrade is shown but not selectable");
    assert.dom(".btcpay-plan-option.blocked input").isDisabled();
  });
});

acceptance("BTCPay | Tickets page when disabled", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: false });

  test("renders nothing to buy", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-checkout-section").doesNotExist();
  });
});
