import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import { btcpayText } from "discourse/plugins/discourse-btcpay-subscriptions/discourse/lib/btcpay-text";

module("Unit | BTCPay | btcpayText", function (hooks) {
  setupTest(hooks);

  test("uses the translation when the setting is blank", function (assert) {
    const text = btcpayText(
      { btcpay_button_label: "" },
      "btcpay_button_label",
      "btcpay.checkout.processing"
    );

    assert.strictEqual(text, "Processing…", "falls back to the translation");
  });

  test("uses the translation when the setting is only whitespace", function (assert) {
    const text = btcpayText(
      { btcpay_button_label: "   " },
      "btcpay_button_label",
      "btcpay.checkout.processing"
    );

    assert.strictEqual(text, "Processing…");
  });

  test("an admin override wins over the translation", function (assert) {
    const text = btcpayText(
      { btcpay_button_label: "Pagar" },
      "btcpay_button_label",
      "btcpay.checkout.processing"
    );

    assert.strictEqual(text, "Pagar");
  });

  test("a missing setting falls back rather than throwing", function (assert) {
    const text = btcpayText(
      {},
      "btcpay_button_label",
      "btcpay.checkout.processing"
    );

    assert.strictEqual(text, "Processing…");
  });
});
