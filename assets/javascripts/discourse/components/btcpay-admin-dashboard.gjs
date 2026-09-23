import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn, get } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import { eq, not, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { PLUGIN_ID } from "../lib/plugin-id";

const FILTERS = ["all", "active", "pending", "expired", "cancelled"];

function profileUrl(username) {
  return getURL(`/u/${username}`);
}

export default class BtcpayAdminDashboard extends Component {
  @tracked subscriptions = [];
  @tracked stats = {};
  @tracked server = {};
  @tracked serverError = null;
  @tracked loading = true;
  @tracked syncing = false;
  @tracked filter = "all";

  reloadTimer = null;

  filters = FILTERS;

  constructor() {
    super(...arguments);
    this.loadServerInfo();
    this.loadSubscriptions();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    if (this.reloadTimer) {
      clearTimeout(this.reloadTimer);
    }
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

  get cryptoList() {
    return (this.server.cryptos || []).join(", ");
  }

  // Plans BTCPay lists but that grant nothing here yet
  get unmappedPlans() {
    return (this.server.plans || []).filter((p) => !p.group_name);
  }

  get missingSettings() {
    return (this.server.missing_settings || []).join(", ");
  }

  get networkClass() {
    return `btcpay-network btcpay-network-${this.server.network || "unknown"}`;
  }

  @action
  async assignGroup(planId, event) {
    const groupName = event.target.value;

    try {
      await ajax("/admin/plugins/btcpay/plan_group", {
        type: "POST",
        data: { plan_id: planId, group_name: groupName },
      });
      await this.loadServerInfo();
    } catch (e) {
      popupAjaxError(e);
    }
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
      this.reloadTimer = setTimeout(() => this.loadSubscriptions(), 3000);
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
            <span class="btcpay-cryptos">{{this.cryptoList}}</span>
          {{/if}}
          {{#if this.server.chain_height}}
            <span class="btcpay-chain-height">
              {{i18n
                "btcpay.admin.chain_height"
                height=this.server.chain_height
              }}
            </span>
          {{/if}}
          {{#if (not this.server.reachable)}}
            <span class="btcpay-not-synced">
              {{i18n "btcpay.admin.unreachable"}}
            </span>
          {{else if (not this.server.fully_synched)}}
            <span class="btcpay-not-synced">
              {{i18n "btcpay.admin.not_synced"}}
            </span>
          {{/if}}
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

        {{#if this.server.plans}}
          <table class="btcpay-admin-table btcpay-plans-table">
            <caption>{{i18n "btcpay.admin.plans_caption"}}</caption>
            <thead>
              <tr>
                <th>{{i18n "btcpay.admin.col_plan"}}</th>
                <th>{{i18n "btcpay.admin.col_price"}}</th>
                <th>{{i18n "btcpay.admin.col_group"}}</th>
              </tr>
            </thead>
            <tbody>
              {{#each this.server.plans as |plan|}}
                <tr>
                  <td>{{plan.name}}</td>
                  <td>{{plan.price}} {{plan.currency}} / {{plan.interval}}</td>
                  <td class="btcpay-plan-group">
                    <select
                      class="btcpay-group-select"
                      {{on "change" (fn this.assignGroup plan.id)}}
                    >
                      <option
                        value=""
                        selected={{not plan.assigned_group}}
                      >{{i18n "btcpay.admin.group_inherit"}}</option>
                      {{#each this.server.groups as |group|}}
                        <option
                          value={{group}}
                          selected={{eq plan.assigned_group group}}
                        >{{group}}</option>
                      {{/each}}
                    </select>

                    {{#if plan.group_name}}
                      <span class="btcpay-plan-source">
                        {{i18n
                          (concat
                            "btcpay.admin.source_" (or plan.source "none")
                          )
                          group=plan.group_name
                        }}
                      </span>
                      {{#unless plan.group_exists}}
                        <span class="btcpay-plan-warning">
                          {{i18n "btcpay.admin.group_missing"}}
                        </span>
                      {{/unless}}
                    {{else}}
                      <span class="btcpay-plan-warning">
                        {{i18n "btcpay.admin.plan_unmapped"}}
                      </span>
                    {{/if}}
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{/if}}

        <table class="btcpay-admin-table">
          <caption>{{i18n "btcpay.admin.subscriptions_caption"}}</caption>
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
                <td>
                  <a href={{profileUrl sub.username}}>{{sub.username}}</a>
                </td>
                <td>{{sub.plan_name}}</td>
                <td>
                  <span class="btcpay-badge btcpay-status-{{sub.status}}">
                    {{i18n (concat "btcpay.status." sub.status)}}
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
