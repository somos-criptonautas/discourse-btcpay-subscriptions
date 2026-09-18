# discourse-btcpay-subscriptions — File Structure

```
discourse-btcpay-subscriptions/
│
├── plugin.rb                          # Settings, routes, PluginStore helpers, plan-mapping parser
│
├── app/
│   ├── controllers/
│   │   ├── btcpay_webhook_controller.rb       # POST /btcpay/webhook — rate limit + content-type + HMAC
│   │   ├── btcpay_checkout_controller.rb      # POST /btcpay/checkout, GET /btcpay/{subscription,plans}
│   │   └── admin/btcpay_admin_controller.rb   # JSON: /admin/plugins/btcpay/{status,subscriptions,sync}
│   ├── jobs/scheduled/btcpay_reconcile.rb     # Hourly tick, gated by btcpay_reconcile_interval_hours
│   └── services/
│       ├── btcpay_api.rb                      # Greenfield client (offerings, plan-checkout, portal)
│       └── btcpay_subscription_manager.rb     # Group add/remove + PluginStore read/write
│
├── config/
│   ├── settings.yml
│   └── locales/{server,client}.en.yml
│
├── assets/
│   ├── stylesheets/btcpay.scss
│   └── javascripts/discourse/
│       ├── admin-btcpay-route-map.js          # (in assets/javascripts/) adminPlugins.show.btcpay
││       ├── initializers/btcpay-subscriptions.js
│       ├── components/
│       │   ├── btcpay-admin-dashboard.gjs
│       │   ├── btcpay-checkout.gjs             # Plan picker + BTCPay modal
│       │   ├── btcpay-page-header.gjs          # Overridable title/intro
│       │   └── btcpay-subscription-status.gjs
│       ├── btcpay-route-map.js                 # /tickets and /billing
│       ├── lib/btcpay-text.js                  # setting override → i18n fallback
│       ├── connectors/
│       │   └── user-main-nav/btcpay-billing-link.gjs
│       └── templates/
│           ├── admin-plugins/show/btcpay.gjs
│           ├── btcpay-tickets.gjs
│           ├── btcpay-billing.gjs
│
├── spec/
│   ├── requests/{webhook,checkout}_spec.rb
│   ├── jobs/btcpay_reconcile_spec.rb
│   └── services/plan_mappings_spec.rb
│
├── docs/                              # Design notes + React checkout mockup
└── README.md
```

## PluginStore Key Schema

```
btcpay_sub:{user_id}        → JSON { customer_id, offering_id, plan_id, plan_name,
                                      group_name, status, phase, auto_renew,
                                      period_end, updated_at }

btcpay_payments:{user_id}   → JSON [ { invoice_id, amount, currency, method, status, paid_at }, ... ]

```

## Request Flow

```
User clicks "Pay with crypto" on /tickets
    → POST /btcpay/checkout (sends discourse_user_id in metadata)
    → Plugin POSTs /api/v1/plan-checkout (storeId + offeringId + planId)
    → Returns invoice id + modal url → BTCPay modal opens in place
      (falls back to redirecting to the checkout URL)

BTCPay payment settles
    → POST /btcpay/webhook (signed with HMAC)
    → InvoiceSettled records the payment
    → PlanStarted activates the subscriber → user added to group

Every btcpay_reconcile_interval_hours
    → Sidekiq job GETs each stored subscriber from BTCPay
    → Compares isActive/phase vs PluginStore
    → Fixes any drift (missed webhooks)
```
