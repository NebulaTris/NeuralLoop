// Study site entry point: routing, header navigation, and live refresh while the pipeline runs.

import { logActivity } from "./core/activity.js";
import { book, go, persist, route, setRenderer, store } from "./ui/context.js";
import { madeWith } from "./core/text.js";
import { $, $$, toast } from "./ui/dom.js";
import { viewBookMap } from "./ui/bookmap.js";
import { viewChapter } from "./ui/chapter.js";
import { viewReview } from "./ui/flashcards.js";
import { viewHome } from "./ui/home.js";

const VIEWS = { home: viewHome, chapter: viewChapter, map: viewBookMap, review: viewReview };
const REFRESH_MS = 10_000;

function render() {
  $("#booktitle").textContent = book.title;
  $("#madewith").textContent = madeWith(book);
  document.title = `${book.title} · NeuralLoop`;
  $$("[data-go]").forEach((button) => {
    const current = route.view === button.dataset.go || (route.view === "chapter" && button.dataset.go === "home");
    button.setAttribute("aria-current", current ? "page" : "false");
  });
  (VIEWS[route.view] || viewHome)($("#main"));
}

/** While materials are still being made, reload book-data.js and redraw when statuses change. */
function refreshWhileWorking() {
  const statusSignature = (data) => JSON.stringify(data.chapters.map((c) => c.status));
  const stillWorking = () =>
    book.chapters.some((c) => Object.values(c.status).some((s) => s === "working" || s === "todo"));
  if (!stillWorking()) return;
  const timer = setInterval(() => {
    const script = document.createElement("script");
    script.src = `book-data.js?t=${Date.now()}`;
    script.onload = () => {
      script.remove();
      const latest = window.BOOK;
      if (!latest || statusSignature(latest) === statusSignature(book)) return;
      Object.assign(book, latest);
      const busy = route.view === "chapter" && ["read", "recall", "map", "space"].includes(route.stage);
      if (!busy) render();
      toast("New study material is ready");
      if (!stillWorking()) clearInterval(timer);
    };
    script.onerror = () => script.remove();
    document.head.appendChild(script);
  }, REFRESH_MS);
}

document.head.insertAdjacentHTML("beforeend", `<style>${window.PIP_CSS || ""}</style>`);
$("#pipicon").innerHTML = window.PIP?.icon || "";
$$("[data-go]").forEach((button) => {
  button.onclick = () => go(button.dataset.go);
});
/** Count study time: 15 s at a time while the page is visible and you've done something in the last minute. */
function startStudyClock() {
  const TICK = 15_000;
  let lastActive = Date.now();
  let ticks = 0;
  ["pointerdown", "keydown", "scroll", "pointermove"].forEach((kind) =>
    window.addEventListener(kind, () => (lastActive = Date.now()), { passive: true }),
  );
  setInterval(() => {
    const media = [...document.querySelectorAll("audio,video")].some((m) => !m.paused);
    if (document.visibilityState !== "visible" || (Date.now() - lastActive > 60_000 && !media)) return;
    logActivity(store, Date.now(), TICK / 1000);
    if (++ticks % 4 === 0) persist(); // save about once a minute
  }, TICK);
}

setRenderer(render);
render();
startStudyClock();
refreshWhileWorking();
