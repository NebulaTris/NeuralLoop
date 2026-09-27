// Settings: nudges, quiet hours, and which Python to use.

import { $, esc, toast } from "./dom.js";
import { app } from "./state.js";
import { invoke, notifications } from "./tauri.js";

const HOURS = Array.from({ length: 24 }, (_, h) => h);
const hourOptions = (chosen) =>
  HOURS.map((h) => `<option value="${h}" ${h === chosen ? "selected" : ""}>${String(h).padStart(2, "0")}:00</option>`).join("");

export async function viewSettings() {
  const settings = await invoke("get_settings");
  app.setup ||= await invoke("check_setup");
  let permission = "unknown";
  try {
    permission = (await notifications.isPermissionGranted()) ? "granted" : "not yet";
  } catch {
    permission = "unknown";
  }
  const setup = app.setup || {};
  $("#main").innerHTML = `<div class="wrap"><div class="settings">
    <h1>Settings</h1>
    <div class="card"><h3>Nudges from Pip</h3>
      <p class="small muted">At most one a day, only when there's something small worth doing: cards that are due, or a chapter loop you left halfway. Never during quiet hours. If you ignore two in a row, Pip backs off.</p>
      <label class="check"><input type="checkbox" id="nud" ${settings.nudges ? "checked" : ""}><span>Let Pip nudge me</span></label>
      <div class="row" style="margin-top:10px">
        <label class="field" style="flex:1"><b>Quiet from</b><select id="qs">${hourOptions(settings.quietStart)}</select></label>
        <label class="field" style="flex:1"><b>until</b><select id="qe">${hourOptions(settings.quietEnd)}</select></label></div>
      <p class="tiny">Notifications: ${permission}.</p>
      <div class="row" style="margin-top:8px"><button class="btn ghost sm" id="perm">Allow notifications</button><button class="btn ghost sm" id="test">Send a test nudge</button><button class="btn ghost sm" id="pause">Pause until tomorrow</button></div></div>
    <div class="card"><h3>Python</h3><p class="small muted">Pip uses Python 3.10+ with the NotebookLM library to prepare books.</p>
      <label class="field"><b>Python to use</b><input type="text" id="py" value="${esc(settings.python)}" placeholder="${esc(setup.python || "Found automatically")}"></label>
      <p class="tiny">Leave empty to find it automatically. Found: ${esc(setup.python || "none")} · NotebookLM ${esc(setup.notebooklm || "not installed")} · ${setup.signedIn ? "signed in" : "not signed in (run: notebooklm login)"}</p></div>
    <div class="row"><button class="btn" id="save">Save settings</button></div></div></div>`;

  $("#perm").onclick = async () => {
    try {
      await notifications.requestPermission();
      toast("Thanks! Pip can nudge you now.");
      viewSettings();
    } catch {
      toast("Open System Settings → Notifications to allow NeuralLoop Books.");
    }
  };
  $("#test").onclick = () => {
    try {
      notifications.sendNotification({ title: "🐾 3 cards are ready", body: "About 1 min with Pip, then you're done for today." });
    } catch {
      toast("Allow notifications first");
    }
  };
  $("#pause").onclick = () => invoke("pause_nudges_today");
  $("#save").onclick = async () => {
    const updated = {
      ...settings,
      python: $("#py").value.trim(),
      nudges: $("#nud").checked,
      quietStart: Number($("#qs").value),
      quietEnd: Number($("#qe").value),
    };
    await invoke("set_settings", { settings: updated });
    app.setup = await invoke("check_setup");
    toast("Saved");
  };
}
