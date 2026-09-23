# Changelog

All notable changes to this plugin. Versions follow the `version:` field in
`plugin.rb`; each entry names anything an operator has to do by hand.

## Unreleased

### Added
- Plans are read from the BTCPay offering automatically. A plan can carry its
  Discourse group in its own BTCPay metadata (`discourse_group`), so the
  `btcpay_plan_mappings` setting is now an optional override rather than the
  catalogue.
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

### Removed
- `docs/btcpay-checkout-preview.jsx`, a React/Stripe prototype that no longer
  matched the plugin.

### Operator actions
- Set `btcpay_offering_id` if it is empty; the admin page names it when missing.
- Add `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceRefund`,
  `SubscriberActivated`, `SubscriberCreated`, `SubscriberCharged`,
  `SubscriberCredited` and `SubscriberNeedUpgrade` to the BTCPay webhook.
