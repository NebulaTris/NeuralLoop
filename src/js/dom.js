// DOM helpers shared by the desktop screens.

export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

export const pip = (pose, extraClass = "") => `<div class="pip moving ${extraClass}">${(window.PIP || {})[pose] || ""}</div>`;

let toastTimer;
export function toast(message) {
  const el = $("#toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

/** Show a modal sheet; `mount(root, close)` wires it up. */
export function openSheet(html, mount) {
  const host = $("#sheet");
  host.innerHTML = `<div class="sheet-bg" id="sbg"><div class="sheet" role="dialog" aria-modal="true">${html}</div></div>`;
  const close = () => {
    host.innerHTML = "";
  };
  $("#sbg").onclick = (event) => {
    if (event.target.id === "sbg") close();
  };
  mount($(".sheet"), close);
}
