import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

function stubActivity(server, helper) {
  server.get("/user_actions.json", () => helper.response({ user_actions: [] }));
}

acceptance("BTCPay | Billing link on your own profile", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });
  needs.pretender(stubActivity);

  test("the profile nav offers the billing tab", async function (assert) {
    await visit("/u/eviltrout/activity");

    assert.dom(".btcpay-billing-nav a").exists();
  });
});

acceptance("BTCPay | Billing link on another profile", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });
  needs.pretender(stubActivity);

  test("is not offered", async function (assert) {
    await visit("/u/charlie/activity");

    assert.dom(".btcpay-billing-nav").doesNotExist();
  });
});

acceptance("BTCPay | Billing link when disabled", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: false });
  needs.pretender(stubActivity);

  test("is not offered", async function (assert) {
    await visit("/u/eviltrout/activity");

    assert.dom(".btcpay-billing-nav").doesNotExist();
  });
});
