// Small DOM helpers and shared pieces of UI (Pip, toasts, confetti, status labels).

import { escapeHtml } from "../core/text.js";

export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
export const esc = escapeHtml;

export const PALETTE = [
  "#E0683F",
  "#5C86E0",
  "#3FA88A",
  "#8A6FE0",
  "#E0A52A",
  "#E2577E",
  "#2FA6B8",
  "#B8743F",
  "#7C9A3A",
  "#C46BC0",
];

export function pip(pose, extraClass = "") {
  return `<div class="pip moving ${extraClass}">${(window.PIP || {})[pose] || ""}</div>`;
}

let toastTimer;
export function toast(message) {
  const el = $("#toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2200);
}

export function confetti() {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const layer = document.createElement("div");
  layer.className = "confetti";
  for (let i = 0; i < 60; i++) {
    const piece = document.createElement("i");
    piece.style.left = `${Math.random() * 100}vw`;
    piece.style.background = PALETTE[i % PALETTE.length];
    piece.style.animationDelay = `${Math.random() * 0.6}s`;
    piece.style.transform = `rotate(${Math.random() * 360}deg)`;
    layer.appendChild(piece);
  }
  document.body.appendChild(layer);
  setTimeout(() => layer.remove(), 2600);
}

export const STATUS = {
  done: { pill: "p-done", label: "Ready" },
  working: { pill: "p-work", label: "Pip is making this" },
  waiting_quota: { pill: "p-wait", label: "Waiting for NotebookLM's daily limit" },
  skipped: { pill: "p-skip", label: "Not made for this chapter" },
  failed: { pill: "p-fail", label: "Couldn't make this" },
  todo: { pill: "p-skip", label: "Queued" },
};
export const statusOf = (status) => STATUS[status] || STATUS.todo;

/** Placeholder shown when a chapter's material isn't ready, explaining why. */
export function notReady(chapter, kind) {
  const status = chapter.status[kind];
  const { pill, label } = statusOf(status);
  const pose = { working: "study", waiting_quota: "nap", failed: "stretch" }[status] || "read";
  let detail = "";
  if (status === "skipped" && (kind === "video" || kind === "audio")) {
    detail = chapter.notes[kind] || `Add it with <code>--media ${chapter.n}</code> next time you run the pipeline.`;
  } else if (status === "waiting_quota") {
    detail = "Pip will try again when the limit resets and pick up right here.";
  } else if (status === "failed") {
    detail = `${esc(chapter.notes[kind])}<br>Run again with <code>--retry</code>.`;
  } else if (status === "working") {
    detail = "This page updates by itself when it's ready.";
  }
  return `<div class="card empty">${pip(pose, "pipmid")}<span class="pill ${pill}">${label}</span>
    <p class="small muted" style="margin-top:8px">${detail}</p></div>`;
}

/** Pip in the side column with a speech bubble. */
export function pipAside(pose, line) {
  return `<aside class="pipside"><div class="bubble">${line}</div>${pip(pose)}</aside>`;
}

export const ICONS = {
  video:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10l5-3v10l-5-3z"/></svg>',
  audio:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><rect x="3" y="14" width="5" height="6" rx="2"/><rect x="16" y="14" width="5" height="6" rx="2"/></svg>',
  study:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M3 5h6a3 3 0 0 1 3 3v12a2 2 0 0 0-2-2H3zM21 5h-6a3 3 0 0 0-3 3v12a2 2 0 0 1 2-2h7z"/></svg>',
  quiz: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 1-1 1.7M12 17h.01"/></svg>',
  cards:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="7" width="13" height="13" rx="3"/><path d="M8 4h10a3 3 0 0 1 3 3v10"/></svg>',
  mindmap:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="5" cy="12" r="2.5"/><circle cx="19" cy="6" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="M7.5 12h4M11.5 12c2 0 2-6 5-6M11.5 12c2 0 2 6 5 6"/></svg>',
  graph:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="6" cy="6" r="2.5"/><circle cx="18" cy="8" r="2.5"/><circle cx="9" cy="18" r="2.5"/><path d="M8.3 7l7.4.6M7 8.3l1.5 7.3M16.4 10l-5.6 6.2"/></svg>',
};
