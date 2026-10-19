"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const C = globalThis.ForcedDarkColors;
const enabled = document.querySelector("#enabled");
const background = document.querySelector("#background");
const status = document.querySelector("#status");
let current = C.defaults;
function display() {
  enabled.checked = current.enabled;
  background.value = current.background;
  document.querySelector("#hex").textContent = current.background.toUpperCase();
  for (const button of document.querySelectorAll("[data-color]")) button.setAttribute("aria-pressed",button.dataset.color === current.background);
}
async function save(value) {
  if (C.settings(value).background !== value.background) {
    status.textContent = "Choose a darker background for comfortable contrast.";
    display();
    return;
  }
  for (const input of document.querySelectorAll("button,input")) input.disabled = true;
  try {
    await api.storage.local.set({forcedDark:value});
    current = value;
    display();
    status.textContent = "Saved. Open websites update automatically.";
  } catch { status.textContent = "Could not save. Please try again."; }
  finally { for (const input of document.querySelectorAll("button,input")) input.disabled = false; }
}
// Avoid overwriting stored preferences before the asynchronous read completes.
for (const input of document.querySelectorAll("button,input")) input.disabled = true;
api.storage.local.get("forcedDark").then(value => {
  current = C.settings(value.forcedDark);
  display();
  for (const input of document.querySelectorAll("button,input")) input.disabled = false;
}).catch(() => { status.textContent = "Could not load preferences. Reopen this menu to try again."; });
enabled.addEventListener("change",() => save({...current,enabled:enabled.checked}));
background.addEventListener("change",() => save({...current,background:background.value}));
for (const button of document.querySelectorAll("[data-color]")) button.addEventListener("click",() => save({...current,background:button.dataset.color}));
document.querySelector("#reset").addEventListener("click",() => save({...current,background:C.defaults.background}));
