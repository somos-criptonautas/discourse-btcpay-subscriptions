# discourse-btcpay-subscriptions

[![Linting and Tests](https://github.com/somos-criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml/badge.svg)](https://github.com/somos-criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml)

**ENGLISH** | [ESPAÑOL](README.es.md)

BTCPay Server subscription integration for Discourse. Sells group access for any crypto BTCPay supports — BTC, XMR, LTC, Lightning — with prices set in fiat. Self-contained: no Stripe and no `discourse-subscriptions` needed.

## Architecture

```
User clicks "Pay with crypto" on Discourse
    → Discourse creates checkout via BTCPay Greenfield API
    → User redirected to BTCPay checkout page
    → User pays → BTCPay settles invoice
    → BTCPay fires webhook → Discourse adds user to group
    → Reconciliation cron catches any missed webhooks (interval is a setting)
```

BTCPay owns the subscription lifecycle. Discourse manages group membership and displays status.

## Requirements

- Discourse 3.4+ (developed and CI-tested against `latest`; the frontend uses `.gjs` components, `discourse/truth-helpers` and `discourse-i18n`, none of which exist on older lines)
- BTCPay Server 2.3+ (with Subscriptions feature)
- Both on the same server (or network-accessible to each other)
- Nginx reverse proxy with valid SSL

## Installation

### 1. Install the plugin

Edit your Discourse `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/somos-criptonautas/discourse-btcpay-subscriptions.git
```

Rebuild Discourse:

```bash
cd /var/discourse
./launcher rebuild app
```

### 2. Configure BTCPay Server

1. Go to **BTCPay Server → Your Store → Subscriptions**
2. Create an **Offering** and one or more **Plans** priced in fiat (e.g., "Premium Monthly — $10/mo")
3. Note the **Offering ID** and the **Plan ID** of each plan — plans live inside an offering
4. Go to **Account → Manage Account → API Keys**
5. Create an API key with these permissions:
   - `btcpay.store.canviewofferings` — read the offering and its plans, read subscribers
   - `btcpay.store.canmanagesubscribers` — create plan checkouts and portal sessions
   - `btcpay.store.canviewinvoices` — read settled invoices for the payment history
   - `btcpay.store.canviewstoresettings` — server/network panel in the Discourse admin page
6. Go to **Store Settings → Webhooks**
7. Create a webhook:
   - **URL:** `https://yourdiscourse.com/btcpay/webhook`
   - **Events:** `PlanStarted`, `SubscriberCreated`, `SubscriberActivated`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `SubscriberCharged`, `SubscriberCredited`, `SubscriberNeedUpgrade`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`
   - **Secret:** Generate and save this — you'll need it for Discourse settings
8. Under **Checkout Appearance**, ensure redirect URLs are allowed

### 3. Configure Discourse

Go to **Admin → Settings** and search for `btcpay`:

| Setting | Value |
|---------|-------|
| `btcpay_enabled` | ✓ |
| `btcpay_server_url` | `https://btcpay.yourdomain.com` |
| `btcpay_api_key` | Your Greenfield API key |
| `btcpay_store_id` | Your BTCPay Store ID |
| `btcpay_offering_id` | The Offering ID holding your plans |
| `btcpay_webhook_secret` | The secret from step 7 above |
| `btcpay_plan_mappings` | See below |
| `btcpay_button_label` | blank (uses the translation) |

**Plan mappings** — one JSON array, all plans in it:

```json
[
  {"plan_id":"BTCPAY_PLAN_ID","group_name":"premium","label":"Premium Monthly"},
  {"plan_id":"OTHER_PLAN_ID","group_name":"vip","label":"VIP Yearly"}
]
```

Invalid JSON is logged and treated as "no plans" — the checkout page will say no plans are available.

The `group_name` must match an existing Discourse group. Create the group first in **Admin → Groups**.

### Customising the text

Every user-facing string is translated (English and Spanish ship with the plugin) and can be overridden two ways:

- **Site settings** for the headline strings — `btcpay_button_label`, `btcpay_tickets_title`, `btcpay_tickets_intro`, `btcpay_billing_title`, `btcpay_billing_intro`, `btcpay_nav_label`. Leave one blank and the translation for each viewer's locale is used; fill it in and that exact text is shown to everyone.
- **Admin → Customize → Text** for anything else, including per-locale overrides. Search for `btcpay.` to find every key.

### 4. Nginx Configuration

If BTCPay and Discourse share a server, add to your Discourse nginx config:

```nginx
# BTCPay webhook endpoint — allow BTCPay to reach Discourse
# This is handled by Discourse's built-in routing, so no extra
# proxy_pass is needed. Just ensure the /btcpay/ path isn't
# blocked by any existing rules.

# If BTCPay is on a separate domain/port and needs to reach
# Discourse internally, you can add:
location /btcpay/webhook {
    proxy_pass http://unix:/var/discourse/shared/standalone/nginx.http.sock;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

If both services are behind the same nginx with valid SSL, webhooks from BTCPay to Discourse will work over `https://` using the public URL.

For same-server setups where BTCPay calls localhost, you may configure the webhook URL as `https://yourdiscourse.com/btcpay/webhook` (going through the public proxy) to ensure SSL is used for HMAC validation integrity.

## How It Works

### Webhook Events

| BTCPay Event | Plugin Action |
|---|---|
| `PlanStarted` | Activates the subscription, adds the user to the mapped group |
| `SubscriberPhaseChanged` | Trial/Normal/Grace update the record; Expired revokes the group |
| `SubscriberDisabled` | `Expired` → expired, `Suspension` → cancelled; removes from group |
| `InvoiceProcessing` | Marks the subscription "pending" — no group access yet |
| `InvoiceReceivedPayment` | Records an unconfirmed payment so the page can show progress |
| `InvoicePaymentSettled` | Flips that payment to confirmed |
| `InvoiceSettled` | Records the payment (and grants access if `PlanStarted` was missed) |
| `InvoiceExpired` | Clears a `pending` record — an unpaid invoice never grants access |
| `InvoiceInvalid` | Marks "disputed", keeps group access, notifies admin |
| `SubscriberCreated` | Records the BTCPay customer id — no access granted |
| `SubscriberActivated` | Restores access after an unsuspension |
| `SubscriberCharged` | Records a renewal paid from the subscriber's BTCPay credit |
| `SubscriberCredited` | Records a credit top-up in the payment history |
| `SubscriberNeedUpgrade` | Flags the account and PMs an admin; access untouched |

Three of BTCPay's invoice events are missing from the Greenfield swagger but do exist and appear in the webhook UI — the plugin handles all three:

| Webhook UI label | Event type | What the plugin does |
|---|---|---|
| Invoice - Expired Paid Partial | `InvoiceExpiredPaidPartial` | PMs an admin with the amount received; clears the pending record |
| Invoice - Paid Late | `InvoicePaidAfterExpiration` | PMs an admin — the invoice had expired, so BTCPay granted nothing and the money is sitting there |
| Invoice - Refund | `InvoiceRefund` | PMs an admin with the pull payment id; group access is left alone |

The same facts also arrive as flags on the documented events, and are handled there too, deduplicated per invoice so ticking both boxes does not double-alert:

| Fact | Flag | What the plugin does |
|---|---|---|
| Partial payment | `InvoiceExpired.partiallyPaid` | Same alert as `InvoiceExpiredPaidPartial`, sent once |
| Late payment | `InvoiceReceivedPayment.afterExpiration` | Stored on the payment progress entry |
| Overpayment | `InvoiceSettled.overPaid` | PMs an admin to refund the difference from BTCPay |
| Marked paid by hand | `InvoiceSettled.manuallyMarked` | Logged, so a manual settle is traceable |

Not subscribed: `InvoiceCreated` (nothing to do yet) and `PaymentReminder` (BTCPay emails the subscriber itself).

### Trials, grace periods and tier changes

- **Trials and grace** come from BTCPay's subscription phase (`Trial`, `Normal`, `Grace`, `Expired`). `/billing` shows "Trial ends …" during a trial and "Payment overdue — access continues until …" during grace; access is only revoked when BTCPay reports `Expired` or disables the subscriber.
- **Payment progress**: on-chain payments take minutes to hours, so `InvoiceReceivedPayment` / `InvoicePaymentSettled` are mirrored into a short-lived record and shown live on the page — "0.0004 received via BTC — unconfirmed" — instead of leaving the payer staring at nothing. It is cleared when the invoice settles, expires or is invalidated.
- **Upgrades**: a subscriber picking a more expensive plan gets a checkout with `onPayBehavior: HardMigration`, so the new tier starts immediately and BTCPay refunds the unused part of the old one. The new plan's group is added on `PlanStarted`.
- **Downgrades are not implemented yet**: the cheaper plan is shown but not selectable, and the server rejects it with 422 even if the client is bypassed. Prices are compared against BTCPay's own plan prices, never the client's.

### Safety Mechanisms

- **HMAC validation** on every webhook with consecutive-failure alerting
- **Idempotent processing** — duplicate invoice deliveries are safely ignored
- **Reconciliation cron** catches missed webhooks (`btcpay_reconcile_interval_hours`, default 4)
- **Rate limits** — 60 webhook deliveries/min per IP, 5 checkouts/min and 20/hour per user
- **user_id based mapping** — immune to Discourse username changes
- **Admin PMs** for: HMAC failures, missing groups, refund disputes

### User Flow

1. User opens `/tickets` (linked from the sidebar)
2. Picks a plan — the price shown is the fiat price BTCPay charges, fetched live and cached for 10 minutes
3. Clicks **Pay with crypto** → BTCPay's checkout opens in a modal over the page; the user never leaves Discourse
4. Pays with any method the store accepts (BTC, XMR, LTC, Lightning, …)
5. `InvoiceProcessing` marks the subscription pending; the page polls and flips to "Payment received" once `InvoiceSettled` grants the group
6. Status and payment history live at `/billing`, also linked from the user profile nav
7. On renewal: BTCPay sends the reminder → user pays → access continues. On lapse: webhook fires → user removed from group

If the modal script cannot load (CSP, offline BTCPay asset host), the button falls back to a full redirect to BTCPay and back to `btcpay_redirect_after_checkout`.

## PluginStore Schema

```
# All rows live under plugin_name = "discourse-btcpay-subscriptions"

sub:{user_id}          → { customer_id, offering_id, plan_id, plan_name,
                           group_name, status, phase, auto_renew, period_end,
                           trial_end, grace_period_end, next_plan_id,
                           next_plan_name, next_plan_at, needs_upgrade,
                           updated_at }

payments:{user_id}     → [ { invoice_id, amount, currency, payment_method,
                             status, paid_at }, ... ] (last 100)

progress:{user_id}     → { invoice_id, payments: [ { id, value, method, status,
                           settled, after_expiration, received_at } ],
                           updated_at }   (cleared when the invoice resolves)

processed_invoices     → [ "invoice_id", ... ] (last 1000, settlement idempotency)

alerts                 → [ "partial:INV1", "over:INV2", ... ] (last 500, one-shot
                           admin alerts)

hmac_failures          → { count, last_at }

reconcile_last_run_at  → ISO8601 timestamp of the last completed sweep
reconcile_cursor       → key the next reconcile tick resumes from ("" = start)
```

Inspect them with:

```sql
SELECT key, value FROM plugin_store_rows
WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

### What leaves your forum

Each checkout sends BTCPay the payer's **Discourse user id and username**, and the plan id, as invoice and subscriber metadata. Nothing else — no email, no posts, no IP. BTCPay returns a customer id, plan and period data, and payment amounts, which are stored in the plugin store as described above. The only external host contacted is the one in `btcpay_server_url`.

## Upgrading, disabling, removing

**Upgrade:** `cd /var/discourse && ./launcher rebuild app` picks up the latest commit of the plugin, exactly like the install. There are no database migrations and no renamed settings or storage keys, so upgrades are in place and reversible by checking out an older commit and rebuilding. Check [CHANGELOG.md](CHANGELOG.md) before upgrading.

**Disable:** turn off `btcpay_enabled`. The scheduled job stops doing work, the webhook and checkout endpoints refuse requests, and the JS never registers its routes or links. Nothing is deleted, and group memberships already granted stay as they are — Discourse groups are the source of truth for access, not this plugin.

**Remove:** delete the plugin from `app.yml` and rebuild. **Plugin-store data is kept on purpose** — subscription records, payment history and the BTCPay customer ids survive an uninstall so that reinstalling does not lose paid subscribers' history. To purge it deliberately:

```sql
DELETE FROM plugin_store_rows WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

Records belonging to a **deleted user** are removed automatically when Discourse destroys the account.

**Support:** open an issue at https://github.com/somos-criptonautas/discourse-btcpay-subscriptions/issues with your Discourse and BTCPay versions, the relevant `/logs` entries (search `DiscourseBtcpay`), and the BTCPay webhook delivery log for the event in question.

## Troubleshooting

**Webhook not received:** Check BTCPay webhook delivery log. Ensure the URL is reachable. Test with `curl -X POST https://yourdiscourse.com/btcpay/webhook`.

**HMAC failures:** Verify the webhook secret matches exactly in both BTCPay and Discourse settings. No trailing spaces.

**User not added to group:** Check Discourse `/logs` for `DiscourseBtcpay` entries. Verify the plan mapping JSON is valid and the group exists.

**Admin page 404s:** the config page lives at **Admin → Plugins → BTCPay Subscriptions** (`/admin/plugins/discourse-btcpay-subscriptions`), not `/admin/plugins/btcpay` — that prefix serves the plugin's JSON endpoints only. A stale bookmark to the old path will 404.

**Admin page says "not fully configured":** it now lists the settings that are still blank. `btcpay_offering_id` is the one most often missed — it was added after the first release. If every setting is filled and it still complains, the page shows the BTCPay error instead: check `btcpay_server_url` and that the API key carries `canviewofferings`.

**Manual sync:** Admin → Plugins → BTCPay → "Sync with BTCPay" button (bypasses the interval).

**Wrong network:** the admin page shows a network label next to the server URL and chain height. BTCPay's API exposes no network field, so the label is **inferred from the chain tip** of BTC (or the first chain the server reports) — treat it as a sanity check, not an authority. "unknown" means BTCPay returned no sync status.

## Testing on testnet

Nothing in the plugin is BTC-specific: it reads whatever payment method BTCPay reports as paid, so XMR, LTC, DOGE and Lightning all work the same. Testnet is just a BTCPay server running on a test chain.

### 1. Get a testnet BTCPay

Either use the public demo (fastest, no setup, wiped periodically):

- https://testnet.demo.btcpayserver.org — register, create a store, done.

Or run your own on testnet/regtest:

```bash
git clone https://github.com/btcpayserver/btcpayserver-docker
cd btcpayserver-docker
export BTCPAY_HOST="btcpay.test.yourdomain.com"
export NBITCOIN_NETWORK="testnet"          # or "regtest" for instant blocks
export BTCPAYGEN_CRYPTO1="btc"
export BTCPAYGEN_CRYPTO2="xmr"             # add more to test multi-crypto
export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-s"
. ./btcpay-setup.sh -i
```

Testnet sync takes a few hours; regtest is instant but you mine your own blocks.

### 2. Set up the store

1. Store → Wallets → BTC → connect an existing wallet with a **tpub** (testnet xpub) or let BTCPay generate one. Save the seed.
2. Store → Subscriptions → create an Offering and a Plan priced in **USD** (e.g. 10 USD / month). Copy the Offering ID into `btcpay_offering_id` and each Plan ID into `btcpay_plan_mappings`. BTCPay converts USD to crypto at checkout using its rate provider — Discourse only ever shows the USD figure.
3. Account → API Keys → create a key with `canviewofferings`, `canmanagesubscribers`, `canviewinvoices` and `canviewstoresettings`.

### 3. Point Discourse at it

Set `btcpay_server_url` to the testnet host, plus the API key, store ID and plan mappings. **Admin → Plugins → BTCPay** shows a `TESTNET` badge, the BTCPay version, the chain tip and the crypto codes the server reports — confirm it says testnet before you go further.

### 4. Make webhooks reachable

BTCPay must reach your Discourse over HTTPS. For a local dev Discourse, tunnel it:

```bash
cloudflared tunnel --url http://localhost:3000
# or: ngrok http 3000
```

Then in Discourse set `DISCOURSE_HOSTNAME`/`force_https` to the tunnel host, and point the BTCPay webhook at `https://<tunnel-host>/btcpay/webhook` with events `PlanStarted`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`.

### 5. Run a payment

1. Open `/tickets` on Discourse as a normal (non-admin) user.
2. Pick a plan → **Pay with crypto** → BTCPay's modal opens over the page.
3. Pay from a testnet wallet. Free coins:
   - BTC testnet3: https://coinfaucet.eu/en/btc-testnet/ or https://bitcoinfaucet.uo1.net
   - BTC signet: https://signetfaucet.com
   - LTC testnet: https://testnet-faucet.com/ltc-testnet
   - Monero stagenet: https://community.rino.io/faucet/stagenet/
   - regtest: `bitcoin-cli -regtest generatetoaddress 101 <addr>` — no faucet needed
4. Watch the states: as soon as the tx hits the mempool BTCPay fires `InvoiceProcessing` → the plugin marks the subscription **pending** (no group yet). After confirmations `InvoiceSettled` records the payment and `PlanStarted` grants the group; the page flips to "Payment received".

### 6. Verify

```bash
# in the Discourse container
./launcher enter app
rails c
> DiscourseBtcpay.get_subscription(User.find_by(username: "tester").id)
> DiscourseBtcpay.get_payments(User.find_by(username: "tester").id)
```

The payment record's `payment_method` is whatever settled it (`BTC`, `XMR`, `BTC-LightningNetwork`, …), not a hardcoded BTC.

Also check **BTCPay → Store → Webhooks → Deliveries** for 200 responses. A 401 there means the secret doesn't match; a 415 means something other than `application/json` was posted.

### 7. Test the failure paths

| Scenario | How to trigger | Expected |
|---|---|---|
| Missed webhook | Disable the webhook in BTCPay, pay, then re-enable | Admin → BTCPay → **Sync with BTCPay** grants the group |
| Abandoned invoice | Start a checkout, never pay | Stays `pending`, then `expired` on `InvoiceExpired` (or within 24h via reconcile) |
| BTCPay down | Stop the container, click Pay | Error message on the page, no state written, reconcile retries next hour |
| Bad secret | Change `btcpay_webhook_secret` | 401 in BTCPay delivery log; after 3 failures an admin PM |
| Refund | Mark an invoice invalid in BTCPay | Status `disputed`, group access kept, admin PM |

## Development

Tests run in CI on every push via the official Discourse plugin workflow (RuboCop, ESLint, Prettier, Stylelint, ember-template-lint, RSpec).

Locally:

```bash
cd /var/discourse && ./launcher enter app

# Backend
bundle exec rspec plugins/discourse-btcpay-subscriptions/spec

# Frontend (QUnit, needs a built Ember app)
bin/rake plugin:qunit['discourse-btcpay-subscriptions']
```

CI runs both, against `latest` and against `stable`.

Frontend linting (needs Node 22+ and pnpm):

```bash
pnpm install && pnpm lint
```

## Translations

English and Spanish ship with the plugin (`config/locales/{client,server}.{en,es}.yml`). Discourse picks the locale from each user's interface language.

## License

MIT
