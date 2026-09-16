# discourse-btcpay-subscriptions

[![Linting and Tests](https://github.com/somos-criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml/badge.svg)](https://github.com/somos-criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml)

*[Read me in English](README.md)*

Integración de suscripciones de BTCPay Server para Discourse. Añade el pago con Bitcoin/Monero junto a Stripe en la página de suscripciones de tu foro.

## Arquitectura

```
El usuario pulsa "Pagar con Bitcoin" en Discourse
    → Discourse crea el checkout con la API Greenfield de BTCPay
    → El usuario es redirigido a la página de pago de BTCPay
    → Paga → BTCPay liquida la factura
    → BTCPay dispara el webhook → Discourse añade al usuario al grupo
    → La tarea de reconciliación recupera los webhooks perdidos
```

BTCPay es el dueño del ciclo de vida de la suscripción. Discourse gestiona la pertenencia al grupo y muestra el estado.

## Requisitos

- Discourse 2.7+
- BTCPay Server 2.3+ (con la función de Suscripciones)
- Ambos en el mismo servidor (o accesibles entre sí por red)
- Nginx como proxy inverso con SSL válido

## Instalación

### 1. Instalar el plugin

Edita el `app.yml` de tu Discourse:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/somos-criptonautas/discourse-btcpay-subscriptions.git
```

Reconstruye Discourse:

```bash
cd /var/discourse
./launcher rebuild app
```

### 2. Configurar BTCPay Server

1. Ve a **BTCPay Server → Tu tienda → Subscriptions**
2. Crea una **Offering** y uno o varios **Plans** (p. ej. "Premium Mensual — 10 $/mes")
3. Anota el **Plan ID** de cada plan
4. Ve a **Account → Manage Account → API Keys**
5. Crea una clave de API con estos permisos:
   - `btcpay.store.canviewinvoices`
   - `btcpay.store.cancreateinvoice`
   - `btcpay.store.canviewsubscriptions`
   - `btcpay.store.cancreatesubscriptioncheckout`
6. Ve a **Store Settings → Webhooks**
7. Crea un webhook:
   - **URL:** `https://tudiscourse.com/btcpay/webhook`
   - **Eventos:** `InvoiceSettled`, `InvoiceProcessing`, `InvoiceInvalid`, `SubscriptionExpired`, `SubscriptionCancelled`
   - **Secreto:** genéralo y guárdalo — lo necesitas en los ajustes de Discourse
8. En **Checkout Appearance**, asegúrate de permitir las URLs de redirección

### 3. Configurar Discourse

Ve a **Admin → Ajustes** y busca `btcpay`:

| Ajuste | Valor |
|---------|-------|
| `btcpay_enabled` | ✓ |
| `btcpay_server_url` | `https://btcpay.tudominio.com` |
| `btcpay_api_key` | Tu clave de API Greenfield |
| `btcpay_store_id` | El ID de tu tienda de BTCPay |
| `btcpay_webhook_secret` | El secreto del paso 7 |
| `btcpay_plan_mappings` | Ver abajo |
| `btcpay_button_label` | `Pagar con Bitcoin` |
| `btcpay_reconcile_interval_hours` | `4` |

**Correspondencia de planes** — un único array JSON con todos los planes:

```json
[
  {"plan_id":"ID_DEL_PLAN","group_name":"premium","label":"Premium Mensual"},
  {"plan_id":"OTRO_ID","group_name":"vip","label":"VIP Anual"}
]
```

Si el JSON no es válido se registra el error y se trata como "sin planes": la página de pago dirá que no hay planes disponibles.

El `group_name` debe coincidir con un grupo existente de Discourse. Créalo antes en **Admin → Grupos**.

### 4. Configuración de Nginx

Si BTCPay y Discourse comparten servidor, no hace falta nada extra: el enrutado de Discourse ya sirve `/btcpay/`. Solo asegúrate de que ninguna regla existente bloquee esa ruta.

Usa siempre la URL pública (`https://tudiscourse.com/btcpay/webhook`) como destino del webhook, para que la validación HMAC viaje sobre SSL.

## Cómo funciona

### Eventos del webhook

| Evento de BTCPay | Acción del plugin |
|---|---|
| `InvoiceProcessing` | Marca la suscripción como "pendiente" |
| `InvoiceSettled` | Activa la suscripción, añade al grupo y registra el pago |
| `InvoiceInvalid` | Marca "en disputa", mantiene el acceso y avisa al admin |
| `SubscriptionExpired` | Saca al usuario del grupo, marca "vencida" |
| `SubscriptionCancelled` | Saca al usuario del grupo, marca "cancelada" |

### Mecanismos de seguridad

- **Validación HMAC** en cada webhook, con aviso tras fallos consecutivos
- **Validación de content-type** — solo se acepta `application/json`
- **Procesamiento idempotente** — las entregas duplicadas se ignoran
- **Límites de tasa** — 60 webhooks/min por IP, 5 checkouts/min y 20/hora por usuario
- **Reconciliación periódica** (`btcpay_reconcile_interval_hours`, 4 por defecto)
- **Mapeo por user_id** — inmune a los cambios de nombre de usuario
- **MP al admin** ante: fallos de HMAC, grupos inexistentes y disputas

### Flujo del usuario

1. Entra en la página de suscripciones de Discourse
2. Ve las opciones de Stripe (existentes) + la sección "Pagar con Bitcoin"
3. Elige un plan y pulsa el botón
4. Va a BTCPay → paga con BTC/XMR/Lightning
5. Vuelve a Discourse → ve su suscripción activa en `/my/billing` (también enlazada desde su perfil)
6. Renovación: BTCPay envía el aviso → paga → mantiene el acceso
7. Impago: llega el webhook → sale del grupo

## Esquema del PluginStore

```
btcpay_sub:{user_id}       → { subscription_id, plan_id, plan_name, group_name,
                                status, period_start, period_end, updated_at }

btcpay_payments:{user_id}  → [ { invoice_id, amount, currency, payment_method,
                                 status, paid_at }, ... ]

processed_invoices         → [ "invoice_id_1", ... ] (últimas 1000)

hmac_failures              → { count, last_at }

reconcile_last_run_at      → marca de tiempo ISO8601 de la última reconciliación
```

## Resolución de problemas

**No llega el webhook:** revisa el registro de entregas en BTCPay y que la URL sea accesible.

**Fallos de HMAC:** comprueba que el secreto coincide exactamente en BTCPay y en Discourse, sin espacios.

**El usuario no entra al grupo:** mira `/logs` buscando `DiscourseBtcpay`. Verifica que el JSON de planes sea válido y que el grupo exista.

**Sincronización manual:** Admin → Plugins → BTCPay → botón "Sincronizar con BTCPay" (ignora el intervalo).

**Red equivocada:** la página de admin muestra la red que reporta BTCPay (mainnet / testnet) junto a la URL del servidor y la altura de la cadena. Se deduce de la punta de la cadena; "red desconocida" significa que BTCPay no devolvió estado de sincronización.

## Desarrollo

Los tests se ejecutan en CI en cada push con el workflow oficial de plugins de Discourse (RuboCop, ESLint, Prettier, Stylelint, ember-template-lint y RSpec).

En local:

```bash
cd /var/discourse && ./launcher enter app
bundle exec rspec plugins/discourse-btcpay-subscriptions/spec
```

Linting del frontend (requiere Node 22+ y pnpm):

```bash
pnpm install && pnpm lint
```

## Traducciones

El plugin incluye inglés y español (`config/locales/{client,server}.{en,es}.yml`). Discourse elige el idioma según la preferencia de cada usuario.

## Licencia

MIT
