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
// Whichever nav this core renders, the billing link belongs in it.
acceptance("BTCPay | Billing link in the user nav sidebar", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true, sidebar_user_navigation: true });
  needs.pretender(stubActivity);

  test("the profile section lists the billing tab", async function (assert) {
    await visit("/u/eviltrout/activity");

    if (!document.querySelector("#sidebar-section-content-user-nav-profile")) {
      assert
        .dom(".btcpay-billing-nav a")
        .exists("no panel on this core, so the outlet link stands in");
      return;
    }

    assert
      .dom('[data-list-item-name="user-nav-btcpay-billing"] a')
      .exists("the panel carries the billing link");
  });
});
