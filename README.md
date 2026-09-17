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

- Discourse 2.7+
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
2. Create an **Offering** and one or more **Plans** (e.g., "Premium Monthly — $10/mo")
3. Note the **Plan ID** for each plan
4. Go to **Account → Manage Account → API Keys**
5. Create an API key with these permissions:
   - `btcpay.store.canviewinvoices`
   - `btcpay.store.cancreateinvoice`
   - `btcpay.store.canviewsubscriptions`
   - `btcpay.store.cancreatesubscriptioncheckout`
6. Go to **Store Settings → Webhooks**
7. Create a webhook:
   - **URL:** `https://yourdiscourse.com/btcpay/webhook`
   - **Events:** `InvoiceSettled`, `InvoiceProcessing`, `InvoiceExpired`, `InvoiceInvalid`, `SubscriptionExpired`, `SubscriptionCancelled`
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
| `btcpay_webhook_secret` | The secret from step 7 above |
| `btcpay_plan_mappings` | See below |
| `btcpay_button_label` | `Pay with crypto` |

**Plan mappings** — one JSON array, all plans in it:

```json
[
  {"plan_id":"BTCPAY_PLAN_ID","group_name":"premium","label":"Premium Monthly"},
  {"plan_id":"OTHER_PLAN_ID","group_name":"vip","label":"VIP Yearly"}
]
```

Invalid JSON is logged and treated as "no plans" — the checkout page will say no plans are available.

The `group_name` must match an existing Discourse group. Create the group first in **Admin → Groups**.

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
| `InvoiceProcessing` | Marks subscription as "pending" in PluginStore |
| `InvoiceSettled` | Activates subscription, adds user to group, records payment |
| `InvoiceExpired` | Clears a `pending` record — an unpaid invoice never grants access |
| `InvoiceInvalid` | Marks as "disputed", keeps group access, notifies admin |
| `SubscriptionExpired` | Removes user from group, marks expired |
| `SubscriptionCancelled` | Removes user from group, marks cancelled |

### Safety Mechanisms

- **HMAC validation** on every webhook with consecutive-failure alerting
- **Idempotent processing** — duplicate invoice deliveries are safely ignored
- **Reconciliation cron** catches missed webhooks (`btcpay_reconcile_interval_hours`, default 4)
- **Rate limits** — 60 webhook deliveries/min per IP, 5 checkouts/min and 20/hour per user
- **user_id based mapping** — immune to Discourse username changes
- **Admin PMs** for: HMAC failures, missing groups, refund disputes

### User Flow

1. User opens `/subscribe` (linked from the sidebar)
2. Picks a plan — the price shown is the fiat price BTCPay charges, fetched live and cached for 10 minutes
3. Clicks **Pay with crypto** → BTCPay's checkout opens in a modal over the page; the user never leaves Discourse
4. Pays with any method the store accepts (BTC, XMR, LTC, Lightning, …)
5. `InvoiceProcessing` marks the subscription pending; the page polls and flips to "Payment received" once `InvoiceSettled` grants the group
6. Status and payment history live at `/my/billing`, also linked from the user profile nav
7. On renewal: BTCPay sends the reminder → user pays → access continues. On lapse: webhook fires → user removed from group

If the modal script cannot load (CSP, offline BTCPay asset host), the button falls back to a full redirect to BTCPay and back to `btcpay_redirect_after_checkout`.

## PluginStore Schema

```
btcpay_sub:{user_id}       → { subscription_id, plan_id, plan_name, group_name,
                                status, period_start, period_end, updated_at }

btcpay_payments:{user_id}  → [ { invoice_id, amount, currency, payment_method,
                                  status, paid_at }, ... ]

btcpay_plans                → [ { btcpay_plan_id, name, group_name, price,
                                  currency, interval }, ... ]

processed_invoices          → [ "invoice_id_1", "invoice_id_2", ... ] (last 1000)

hmac_failures               → { count, last_at }
```

## Troubleshooting

**Webhook not received:** Check BTCPay webhook delivery log. Ensure the URL is reachable. Test with `curl -X POST https://yourdiscourse.com/btcpay/webhook`.

**HMAC failures:** Verify the webhook secret matches exactly in both BTCPay and Discourse settings. No trailing spaces.

**User not added to group:** Check Discourse `/logs` for `DiscourseBtcpay` entries. Verify the plan mapping JSON is valid and the group exists.

**Manual sync:** Admin → Plugins → BTCPay → "Sync with BTCPay" button (bypasses the interval).

**Wrong network:** the admin page shows the network BTCPay reports (mainnet / testnet) next to the server URL and chain height. It is derived from the chain tip; "unknown" means BTCPay returned no sync status.

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
2. Store → Subscriptions → create an Offering and a Plan priced in **USD** (e.g. 10 USD / month). BTCPay converts USD to crypto at checkout using its rate provider — Discourse only ever shows the USD figure.
3. Account → API Keys → create a key with `canviewinvoices`, `cancreateinvoice`, `canviewsubscriptions`, `cancreatesubscriptioncheckout`, and `canviewstoresettings` (needed for the network/server info panel).

### 3. Point Discourse at it

Set `btcpay_server_url` to the testnet host, plus the API key, store ID and plan mappings. **Admin → Plugins → BTCPay** shows a `TESTNET` badge, the BTCPay version, the chain tip and the crypto codes the server reports — confirm it says testnet before you go further.

### 4. Make webhooks reachable

BTCPay must reach your Discourse over HTTPS. For a local dev Discourse, tunnel it:

```bash
cloudflared tunnel --url http://localhost:3000
# or: ngrok http 3000
```

Then in Discourse set `DISCOURSE_HOSTNAME`/`force_https` to the tunnel host, and point the BTCPay webhook at `https://<tunnel-host>/btcpay/webhook` with events `InvoiceProcessing`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceInvalid`, `SubscriptionExpired`, `SubscriptionCancelled`.

### 5. Run a payment

1. Open `/subscribe` on Discourse as a normal (non-admin) user.
2. Pick a plan → **Pay with crypto** → BTCPay's modal opens over the page.
3. Pay from a testnet wallet. Free coins:
   - BTC testnet3: https://coinfaucet.eu/en/btc-testnet/ or https://bitcoinfaucet.uo1.net
   - BTC signet: https://signetfaucet.com
   - LTC testnet: https://testnet-faucet.com/ltc-testnet
   - Monero stagenet: https://community.rino.io/faucet/stagenet/
   - regtest: `bitcoin-cli -regtest generatetoaddress 101 <addr>` — no faucet needed
4. Watch the states: as soon as the tx hits the mempool BTCPay fires `InvoiceProcessing` → the plugin marks the subscription **pending** (no group yet). After confirmations it fires `InvoiceSettled` → the user is added to the mapped group and the modal page flips to "Payment received".

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
bundle exec rspec plugins/discourse-btcpay-subscriptions/spec
```

Frontend linting (needs Node 22+ and pnpm):

```bash
pnpm install && pnpm lint
```

## Translations

English and Spanish ship with the plugin (`config/locales/{client,server}.{en,es}.yml`). Discourse picks the locale from each user's interface language.

## License

MIT
