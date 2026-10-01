import { getOwner } from "@ember/owner";
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

// The profile nav becomes a sidebar panel under `sidebar_user_navigation`, and
// that panel ignores plugin outlets — the link has to be registered with core.
acceptance("BTCPay | Billing link in the user nav sidebar", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true, sidebar_user_navigation: true });
  needs.pretender(stubActivity);

  test("the profile section lists the billing tab", async function (assert) {
    await visit("/u/eviltrout/activity");

    const settings = getOwner(this).lookup("service:site-settings");
    if (settings.sidebar_user_navigation === undefined) {
      assert.dom(".btcpay-billing-nav a").exists("this core has no panel yet");
      return;
    }

    assert
      .dom("#sidebar-section-content-user-nav-profile")
      .exists("the panel replaced the horizontal nav");
    assert
      .dom('[data-list-item-name="user-nav-btcpay-billing"] a')
      .exists("and carries the billing link");
  });
});
