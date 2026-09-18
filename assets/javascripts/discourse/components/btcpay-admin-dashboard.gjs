import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn, get } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { PLUGIN_ID } from "../lib/plugin-id";

const FILTERS = ["all", "active", "pending", "expired", "cancelled"];

export default class BtcpayAdminDashboard extends Component {
  @tracked subscriptions = [];
  @tracked stats = {};
  @tracked server = {};
  @tracked serverError = null;
  @tracked loading = true;
  @tracked syncing = false;
  @tracked filter = "all";

  filters = FILTERS;

  constructor() {
    super(...arguments);
    this.loadServerInfo();
    this.loadSubscriptions();
  }

  async loadServerInfo() {
    try {
      this.server = await ajax("/admin/plugins/btcpay/status");
    } catch (e) {
      // A failed status call is not the same as "not configured" — say so.
      this.serverError = extractError(e);
    }
  }

  async loadSubscriptions() {
    this.loading = true;
    try {
      const result = await ajax("/admin/plugins/btcpay/subscriptions", {
        data: this.filter === "all" ? {} : { status: this.filter },
      });
      this.subscriptions = result.subscriptions || [];
      this.stats = {
        all: result.total,
        active: result.active,
        expired: result.expired,
        cancelled: result.cancelled,
        pending: result.pending,
        disputed: result.disputed,
      };
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  // Core's own plugin settings page (adminPlugins.show.settings)
  get settingsUrl() {
    return getURL(`/admin/plugins/${PLUGIN_ID}/settings`);
  }

  get missingSettings() {
    return (this.server.missing_settings || []).join(", ");
  }

  get networkClass() {
    return `btcpay-network btcpay-network-${this.server.network || "unknown"}`;
  }

  @action
  setFilter(status) {
    this.filter = status;
    this.loadSubscriptions();
  }

  @action
  async syncNow() {
    this.syncing = true;
    try {
      await ajax("/admin/plugins/btcpay/sync", { type: "POST" });
      // Reload after brief delay to let job run
      setTimeout(() => this.loadSubscriptions(), 3000);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.syncing = false;
    }
  }

  <template>
    <div class="btcpay-admin">
      <h1>{{i18n "btcpay.admin.title"}}</h1>

      <div class="btcpay-admin-server">
        {{#if this.server.configured}}
          <span class={{this.networkClass}}>
            {{if
              this.server.network
              this.server.network
              (i18n "btcpay.admin.network_unknown")
            }}
          </span>
          <span class="btcpay-server-url">{{this.server.server_url}}</span>
          {{#if this.server.version}}
            <span class="btcpay-server-version">v{{this.server.version}}</span>
          {{/if}}
          {{#if this.server.cryptos}}
            <span class="btcpay-cryptos">{{this.server.cryptos}}</span>
          {{/if}}
          {{#if this.server.chain_height}}
            <span class="btcpay-chain-height">
              {{i18n
                "btcpay.admin.chain_height"
                height=this.server.chain_height
              }}
            </span>
          {{/if}}
          {{#unless this.server.reachable}}
            <span class="btcpay-not-synced">
              {{i18n "btcpay.admin.unreachable"}}
            </span>
          {{/unless}}
          {{#unless this.server.fully_synched}}
            <span class="btcpay-not-synced">
              {{i18n "btcpay.admin.not_synced"}}
            </span>
          {{/unless}}
        {{else if this.serverError}}
          <span class="btcpay-not-configured">{{this.serverError}}</span>
        {{else}}
          <span class="btcpay-not-configured">
            {{i18n "btcpay.admin.not_configured"}}
            {{#if this.server.missing_settings}}
              <span class="btcpay-missing-settings">
                {{i18n "btcpay.admin.missing_settings"}}
                <a href={{this.settingsUrl}}>{{this.missingSettings}}</a>
              </span>
            {{/if}}
          </span>
        {{/if}}

        <a
          href={{this.settingsUrl}}
          class="btn btn-default btcpay-settings-btn"
        >
          {{i18n "btcpay.admin.settings"}}
        </a>

        <button
          class="btn btn-default btcpay-sync-btn"
          disabled={{this.syncing}}
          type="button"
          {{on "click" this.syncNow}}
        >
          {{if
            this.syncing
            (i18n "btcpay.admin.syncing")
            (i18n "btcpay.admin.sync")
          }}
        </button>
      </div>

      {{#if this.loading}}
        <p>{{i18n "btcpay.loading"}}</p>
      {{else}}
        <div class="btcpay-admin-stats">
          {{#each this.filters as |status|}}
            <button
              class="btn btcpay-stat
                {{if (eq this.filter status) 'btn-primary' 'btn-default'}}"
              type="button"
              {{on "click" (fn this.setFilter status)}}
            >
              {{i18n (concat "btcpay.status." status)}}:
              {{get this.stats status}}
            </button>
          {{/each}}

          {{#if this.stats.disputed}}
            <button
              class="btn btcpay-stat btn-danger
                {{if (eq this.filter 'disputed') 'btn-primary'}}"
              type="button"
              {{on "click" (fn this.setFilter "disputed")}}
            >
              {{i18n "btcpay.status.disputed"}}:
              {{this.stats.disputed}}
            </button>
          {{/if}}
        </div>

        <table class="btcpay-admin-table">
          <thead>
            <tr>
              <th>{{i18n "btcpay.admin.col_user"}}</th>
              <th>{{i18n "btcpay.admin.col_plan"}}</th>
              <th>{{i18n "btcpay.admin.col_status"}}</th>
              <th>{{i18n "btcpay.admin.col_group"}}</th>
              <th>{{i18n "btcpay.admin.col_period_end"}}</th>
              <th>{{i18n "btcpay.admin.col_payments"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each this.subscriptions as |sub|}}
              <tr>
                <td><a href="/u/{{sub.username}}">{{sub.username}}</a></td>
                <td>{{sub.plan_name}}</td>
                <td>
                  <span class="btcpay-badge btcpay-status-{{sub.status}}">
                    {{sub.status}}
                  </span>
                </td>
                <td>{{sub.group_name}}</td>
                <td>{{sub.period_end}}</td>
                <td>{{sub.payments.length}}</td>
              </tr>
            {{else}}
              <tr>
                <td colspan="6">{{i18n "btcpay.admin.empty"}}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      {{/if}}
    </div>
  </template>
}
