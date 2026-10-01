import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import topicFixtures from "discourse/tests/fixtures/topic";
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
  ],
};

function topicWithWrap(wrap) {
  const topic = cloneJSON(topicFixtures["/t/280/1.json"]);
  topic.post_stream.posts[0].cooked = `<div class="d-wrap" data-wrap="${wrap}"></div>`;
  return topic;
}

acceptance("BTCPay | Plans embedded in a post", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response({
        subscription: null,
        payments: [],
        payment_progress: null,
        portal_url: null,
      })
    );
    server.get("/t/280.json", () =>
      helper.response(topicWithWrap("btcpay-plans"))
    );
  });

  test("[wrap=btcpay-plans] renders the plan picker in the post", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".btcpay-post-embed .btcpay-plan").exists({ count: 1 });
    assert.dom(".btcpay-post-embed .btcpay-checkout-btn").exists();
  });
});

acceptance("BTCPay | Another component's wrap", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWithWrap("donate")));
  });

  test("is left alone", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".btcpay-post-embed").doesNotExist();
    assert.dom('[data-wrap="donate"]').exists();
  });
});
