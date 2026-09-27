// A book's study site, shown inside the app. Progress the site reports is saved by the backend.

import { $, esc } from "./dom.js";
import { app, go } from "./state.js";
import { BOOKS_BASE, invoke } from "./tauri.js";

export function viewBook() {
  const book = app.books.find((b) => b.id === app.view.id) || { title: "" };
  $("#barmid").innerHTML = `<button class="btn ghost sm" id="back">‹ Library</button><b>${esc(book.title)}</b>`;
  $("#back").onclick = () => go("library");
  $("#main").innerHTML =
    `<iframe class="frame" title="${esc(book.title)}" src="${BOOKS_BASE}${encodeURIComponent(app.view.id)}/index.html"></iframe>`;
}

window.addEventListener("message", (event) => {
  if (app.view.name !== "book" || event.data?.type !== "nl-progress") return;
  const frame = $(".frame");
  if (!frame || event.source !== frame.contentWindow) return;
  invoke("save_progress", { bookId: app.view.id, data: event.data.data }).catch(() => {});
});
