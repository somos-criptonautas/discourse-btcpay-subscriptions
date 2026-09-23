# Changelog

All notable changes to this plugin. Versions follow the `version:` field in
`plugin.rb`; each entry names anything an operator has to do by hand.

## Unreleased

### Added
- Plans are read from the BTCPay offering automatically — no plan ids are typed
  into Discourse. Each plan's group comes from a dropdown on the admin page,
  from `discourse_group` in the plan's BTCPay metadata, or from the new
  `btcpay_default_group` setting.
- Admin alerts (underpaid, overpaid, disputes, HMAC failures, …) are translated
  and sent in the recipient admin's own locale instead of hardcoded English.
- Admin page lists every plan in the offering with the group it resolves to,
  and flags plans that map to nothing or to a group that does not exist.
- Settings link on the admin page.

### Changed
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
