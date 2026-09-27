// Desktop app entry point: navigation and events from the backend.

import { viewBook } from "./book.js";
import { $, $$, toast } from "./dom.js";
import { pickBook, refreshBooks, viewLibrary } from "./library.js";
import { viewSettings } from "./settings.js";
import { app, go, setRenderer } from "./state.js";
import { invoke, listen, notifications } from "./tauri.js";

const SCREENS = { library: viewLibrary, book: viewBook, settings: viewSettings };
const PROGRESS_LINE = /✓|added chapter|chapters found/;
const MAX_LOG_LINES = 40;

function render() {
  $$("[data-nav]").forEach((button) => button.setAttribute("aria-current", app.view.name === button.dataset.nav ? "page" : "false"));
  $("#barmid").innerHTML = "";
  SCREENS[app.view.name]();
}

function onPipelineOutput({ bookId, line, done, code, stderr }) {
  const log = (app.logs[bookId] ||= []);
  if (line) {
    log.push(line);
    if (log.length > MAX_LOG_LINES) log.shift();
    if (PROGRESS_LINE.test(line) || log.length % 5 === 0) refreshBooks();
  }
  if (done) {
    refreshBooks();
    toast(code === 0 ? "Your book is ready!" : code === -1 ? "Paused" : "Pip hit a snag. Check the book card.");
    if (code !== 0 && stderr) log.push(stderr.split("\n").slice(-2).join(" "));
  }
}

async function askForNotificationsOnce() {
  try {
    if (!(await notifications.isPermissionGranted())) await notifications.requestPermission();
  } catch {
    // Not available in this environment; Settings explains how to allow them.
  }
}

document.head.insertAdjacentHTML("beforeend", `<style>${window.PIP_CSS || ""}</style>`);
$("#brandpip").innerHTML = window.PIP?.icon || "";
$$("[data-nav]").forEach((button) => {
  button.onclick = () => go(button.dataset.nav);
});
listen("pipeline", onPipelineOutput);
listen("menu-add-book", () => {
  go("library");
  pickBook();
});
listen("toast", toast);
listen("nudge", () => app.view.name === "library" && refreshBooks());
window.addEventListener("focus", () => invoke("nudge_engaged").catch(() => {}));
invoke("nudge_engaged").catch(() => {});
askForNotificationsOnce();
setRenderer(render);
render();
