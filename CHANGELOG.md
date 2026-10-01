# Changelog

All notable changes to this plugin. Versions follow the `version:` field in
`plugin.rb`; each entry names anything an operator has to do by hand.

## 1.0.0 — 2026-09-30

### Added
- Billing lives on the user profile as a **Billing** tab (`/u/<username>/billing`),
  the way Discourse's own subscriptions plugin does it. The old top-level
  `/billing` page is gone; `btcpay_redirect_after_checkout` now points at
  `/my/billing`, which Discourse redirects to the buyer's own tab.
- `[wrap=btcpay-plans]` in a post renders the plan picker inline, so plans can
  be offered from an announcement topic.

### Removed
- The forced sidebar link. `/tickets` is still there, but where it is linked
  from is now the forum's decision — a post embed, a menu item, a topic link.

- One-off donations through a BTCPay Point of Sale app: `POST /btcpay/donate`
  creates the invoice with a server-generated order id, the existing webhook
  attributes the settled payment, and `GET /btcpay/donations` serves totals and
  supporters for a fundraising bar. Optional donor badge (picked on the admin
  page) and gamification points per unit donated.
- Logged-in buyers are no longer asked for an email by BTCPay — theirs is sent
  with the checkout (`btcpay_send_email`).
- Optional anonymous checkout (`btcpay_anonymous_checkout`): a logged-out
  visitor pays, gives BTCPay their email, and is invited to the forum with the
  plan's group attached. The subscription binds to the account on signup.
- Anonymous visitors see plans and prices on /tickets instead of an empty page.
- Plans are read from the BTCPay offering automatically — no plan ids are typed
  into Discourse. Each plan's group comes from a dropdown on the admin page,
  from `discourse_group` in the plan's BTCPay metadata, or from the new
  `btcpay_default_group` setting.
- Admin alerts (underpaid, overpaid, disputes, HMAC failures, …) are translated
  and sent in the recipient admin's own locale instead of hardcoded English.
- Admin page lists every plan in the offering with the group it resolves to,
  and flags plans that map to nothing or to a group that does not exist.
- Settings link on the admin page.

### Fixed
- A second click no longer stacks a second BTCPay checkout overlay; the button
  is inert while a checkout is open, and the overlay is cleared on settle.
- Checkout goes straight to the invoice: Discourse proceeds the plan checkout
  server-side, so there is no second "Subscribe" click on BTCPay and no BTCPay
  redirect that can land on localhost. A plan covered by credit activates with
  no payment step at all.
- Plan descriptions are cooked through Discourse's markdown pipeline, so bold,
  links and lists render on the plan cards.
- `/tickets` and `/billing` no longer 404 when opened directly or refreshed —
  Rails now serves the app shell for both.
- The "no subscription" block is hidden on `/tickets` instead of announcing an
  absence to someone who is about to buy.
- A checkout URL that BTCPay built on the wrong host (typically `localhost`
  behind a proxy that drops Host/X-Forwarded headers) is re-pointed at
  `btcpay_server_url` instead of sending the payer nowhere.

### Changed
- Plan picker restyled as selectable cards using core Discourse tokens.
- The reconcile job processes at most 200 subscribers per tick and resumes from
  a stored cursor, so a large site or a slow BTCPay cannot hold a worker.
- Credit-based payment records key off BTCPay's delivery id instead of the
  clock, so a redelivery no longer duplicates a row.
- Minimum Discourse version corrected to 3.4 — the shipped frontend cannot run
  on the previously declared 2.7.

### Tests
- Frontend QUnit suite (`test/javascripts/`): tickets page plan list and
  upgrade/downgrade states, billing page trial/grace/history, live payment
  progress, admin dashboard plans table and missing-settings warning, and unit
  coverage for the setting-override text helper. CI now runs a `frontend` job
  in addition to the backend one.

### Removed
- The `btcpay_plan_mappings` JSON setting. Plan → group is now set in the UI.
- `docs/btcpay-checkout-preview.jsx`, a React/Stripe prototype that no longer
  matched the plugin.

### Operator actions
- Set `btcpay_offering_id` if it is empty; the admin page names it when missing.
- Re-pick each plan's group on Admin → Plugins → BTCPay (or set
  `btcpay_default_group`). Values in the removed JSON setting are not migrated.
- Add `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceRefund`,
  `SubscriberActivated`, `SubscriberCreated`, `SubscriberCharged`,
  `SubscriberCredited` and `SubscriberNeedUpgrade` to the BTCPay webhook.
