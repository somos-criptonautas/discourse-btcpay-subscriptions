import { i18n } from "discourse-i18n";

// Admin-overridable, still localized: a blank setting falls back to the
// translation for the viewer's locale.
export function btcpayText(siteSettings, settingName, translationKey) {
  const override = siteSettings[settingName];
  return override?.trim() ? override : i18n(translationKey);
}
