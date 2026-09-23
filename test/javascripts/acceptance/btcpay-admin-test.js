import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const SUBSCRIPTIONS = {
  subscriptions: [
    {
      user_id: 1,
      username: "payer",
      plan_name: "Premium",
      status: "active",
      group_name: "premium",
      period_end: "2026-11-01T00:00:00Z",
      payments: [],
    },
  ],
  total: 1,
  active: 1,
  expired: 0,
  cancelled: 0,
  pending: 0,
  disputed: 0,
};

acceptance("BTCPay | Admin dashboard", function (needs) {
  needs.user({ admin: true });
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/admin/plugins/btcpay/status", () =>
      helper.response({
        configured: true,
        missing_settings: [],
        reachable: true,
        server_url: "https://btcpay.example.com",
        offering_id: "off-1",
        version: "2.4.4",
        fully_synched: true,
        chain_height: 2900000,
        network: "testnet",
        cryptos: ["BTC", "XMR"],
        groups: ["premium", "vip"],
        default_group: "",
        plans: [
          {
            id: "plan-1",
            name: "Premium",
            price: "10",
            currency: "USD",
            interval: "Monthly",
            group_name: "premium",
            group_exists: true,
            assigned_group: null,
            source: "btcpay",
          },
          {
            id: "plan-9",
            name: "Orphan",
            price: "5",
            currency: "USD",
            interval: "Monthly",
            group_name: null,
            group_exists: false,
            assigned_group: null,
            source: null,
          },
        ],
      })
    );
    server.get("/admin/plugins/btcpay/subscriptions", () =>
      helper.response(SUBSCRIPTIONS)
    );
  });

  test("shows the network, the plans and the subscribers", async function (assert) {
    await visit("/admin/plugins/discourse-btcpay-subscriptions");

    assert.dom(".btcpay-network").hasText("testnet");
    assert.dom(".btcpay-cryptos").hasText("BTC, XMR");
    assert.dom(".btcpay-plans-table tbody tr").exists({ count: 2 });
    assert
      .dom(".btcpay-plans-table tbody tr:last-child .btcpay-plan-warning")
      .exists("a plan with no group is flagged");
    assert
      .dom(".btcpay-admin-table:last-of-type tbody tr")
      .exists({ count: 1 });
    assert.dom(".btcpay-settings-btn").exists();
  });

  test("offers a group picker per plan", async function (assert) {
    await visit("/admin/plugins/discourse-btcpay-subscriptions");

    assert.dom(".btcpay-group-select").exists({ count: 2 });
    assert
      .dom(".btcpay-plans-table tbody tr:first-child .btcpay-plan-source")
      .includesText("premium", "shows where the group came from");
  });
});

acceptance("BTCPay | Admin dashboard with settings missing", function (needs) {
  needs.user({ admin: true });
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/admin/plugins/btcpay/status", () =>
      helper.response({
        configured: false,
        missing_settings: ["btcpay_offering_id"],
      })
    );
    server.get("/admin/plugins/btcpay/subscriptions", () =>
      helper.response({
        ...SUBSCRIPTIONS,
        subscriptions: [],
        total: 0,
        active: 0,
      })
    );
  });

  test("names the setting that is still blank", async function (assert) {
    await visit("/admin/plugins/discourse-btcpay-subscriptions");

    assert.dom(".btcpay-not-configured").exists();
    assert.dom(".btcpay-missing-settings").includesText("btcpay_offering_id");
  });
});
