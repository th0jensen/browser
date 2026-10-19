"use strict";
importScripts("colors.js");
const api = globalThis.browser ?? globalThis.chrome;
const application = "dev.athas.browser.forced-dark";
const C = globalThis.ForcedDarkColors;
function publish(value) {
  const settings = C.settings(value);
  api.runtime.sendNativeMessage(application,{type:"appearance",...settings}).catch(() => {});
}
api.storage.local.get("forcedDark").then(value => publish(value.forcedDark)).catch(() => publish());
api.storage.onChanged.addListener((changes,area) => {
  if (area === "local" && changes.forcedDark) publish(changes.forcedDark.newValue);
});
