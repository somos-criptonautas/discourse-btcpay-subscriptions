// Same shape as discourse-subscriptions: a sibling of adminPlugins.show named
// after the plugin directory, so this page *is* /admin/plugins/<directory>.
// The static segment wins over show's /:plugin_id, while show's own children
// (e.g. /settings) keep working because they are longer paths.
export default {
  resource: "admin.adminPlugins",
  path: "/plugins",

  map() {
    this.route("discourse-btcpay-subscriptions");
  },
};
