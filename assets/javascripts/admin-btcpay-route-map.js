// Lives outside discourse/ and hangs off adminPlugins.show — the plugin
// config page owns the URL (/admin/plugins/<directory-name>/btcpay).
export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("btcpay");
  },
};
