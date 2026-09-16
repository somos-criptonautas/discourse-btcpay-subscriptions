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
│   │   └── admin/btcpay_admin_controller.rb   # GET /admin/plugins/btcpay — network info + subscriptions
│   ├── jobs/scheduled/btcpay_reconcile.rb     # Hourly tick, gated by btcpay_reconcile_interval_hours
│   └── services/
│       ├── btcpay_api.rb                      # Greenfield client (invoices, subscriptions, server info)
│       └── btcpay_subscription_manager.rb     # Group add/remove + PluginStore read/write
│
├── config/
│   ├── settings.yml
│   └── locales/{server,client}.en.yml
│
├── assets/
│   ├── stylesheets/btcpay.scss
│   └── javascripts/discourse/
│       ├── admin-btcpay-route-map.js          # adminPlugins.btcpay → /admin/plugins/btcpay
│       ├── btcpay-user-route-map.js           # user.billing → /u/:username/billing (/my/billing)
│       ├── initializers/btcpay-subscriptions.js
│       ├── components/
│       │   ├── btcpay-admin-dashboard.gjs
│       │   └── btcpay-subscription-status.gjs
│       ├── connectors/
│       │   ├── discourse-subscriptions-below-stripe/btcpay-button.gjs
│       │   └── user-main-nav/btcpay-billing-link.gjs
│       └── templates/
│           ├── admin-plugins-btcpay.gjs
│           └── user/billing.gjs
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
btcpay_sub:{user_id}        → JSON { subscription_id, plan_id, plan_name, group_name,
                                      status, period_start, period_end }

btcpay_payments:{user_id}   → JSON [ { invoice_id, amount, currency, method, status, paid_at }, ... ]

btcpay_plans                → JSON [ { btcpay_plan_id, name, group_name, price, currency, interval }, ... ]
```

## Request Flow

```
User clicks "Pay with Bitcoin"
    → POST /btcpay/checkout (sends discourse_username in metadata)
    → Plugin calls BTCPay Greenfield API → creates plan checkout
    → Returns checkout URL → user redirected to BTCPay

BTCPay payment settles
    → POST /btcpay/webhook (signed with HMAC)
    → Plugin validates signature
    → Updates PluginStore + adds user to group

Every btcpay_reconcile_interval_hours
    → Sidekiq job calls BTCPay API
    → Compares active subscriptions vs PluginStore
    → Fixes any drift (missed webhooks)
```
