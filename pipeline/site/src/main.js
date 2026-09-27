// Study site entry point: routing, header navigation, and live refresh while the pipeline runs.

import { book, go, route, setRenderer } from "./ui/context.js";
import { $, $$, toast } from "./ui/dom.js";
import { viewBookMap } from "./ui/bookmap.js";
import { viewChapter } from "./ui/chapter.js";
import { viewReview } from "./ui/flashcards.js";
import { viewHome } from "./ui/home.js";

const VIEWS = { home: viewHome, chapter: viewChapter, map: viewBookMap, review: viewReview };
const REFRESH_MS = 10_000;

function render() {
  $("#booktitle").textContent = book.title;
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
setRenderer(render);
render();
refreshWhileWorking();
