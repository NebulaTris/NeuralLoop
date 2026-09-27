// Flashcard review sessions, scheduled with FSRS.

import { dueCards } from "../core/cards.js";
import { formatWait, grade } from "../core/fsrs.js";
import { book, go, now, persist, store } from "./context.js";
import { $, $$, esc, pip } from "./dom.js";

const GRADES = [
  [1, "Again"],
  [2, "Hard"],
  [3, "Good"],
  [4, "Easy"],
];

/** Review `cards` one by one. `done` is [label, callback] for the finish button. */
export function reviewSession(el, cards, title, done) {
  const queue = [...cards];
  let index = 0;
  let flipped = false;
  let remembered = 0;

  const draw = () => {
    if (index >= queue.length) return finished();
    const card = queue[index];
    const state = store.cards[card.id] || {};
    const grades = GRADES.map(
      ([g, label]) =>
        `<button class="g${g}" data-g="${g}">${label}<small>${formatWait(grade(state, g, now()).due, now())}</small></button>`,
    ).join("");
    el.innerHTML = `<p class="small muted" style="text-align:center">${esc(title)} · card ${index + 1} of ${queue.length}</p>
      <div class="fc ${flipped ? "flip" : ""}" id="fc" tabindex="0" role="button" aria-label="${flipped ? "Answer shown" : "Show answer"}">
        <div class="fc-in"><div class="face"><small>Question</small>${esc(card.front)}</div><div class="face back"><small>Answer</small>${esc(card.back)}</div></div></div>
      ${flipped ? `<div class="grades">${grades}</div>` : '<div class="row" style="justify-content:center;margin-top:14px"><button class="btn" id="show">Show answer</button></div>'}
      <p class="tiny" style="text-align:center;margin-top:10px">Space flips · 1–4 grades</p>`;
    $("#fc").onclick = flip;
    if (!flipped) $("#show").onclick = flip;
    $$("[data-g]", el).forEach((button) => {
      button.onclick = () => rate(Number(button.dataset.g));
    });
  };
  const flip = () => {
    if (!flipped) {
      flipped = true;
      draw();
    }
  };
  const rate = (g) => {
    const card = queue[index];
    store.cards[card.id] = grade(store.cards[card.id] || {}, g, now());
    persist();
    if (g >= 3) remembered += 1;
    if (g === 1) queue.push(card);
    index += 1;
    flipped = false;
    draw();
  };
  const finished = () => {
    el.innerHTML = `<div class="card empty">${pip(remembered ? "hug" : "read", "pipmid")}
      <h3>${queue.length ? "All done!" : "Nothing due right now"}</h3>
      <p class="muted">${queue.length ? `${remembered} of ${queue.length} remembered. Each card comes back right before you'd forget it.` : "Come back later; Pip will have cards ready."}</p>
      ${done ? `<button class="btn ghost" id="dn">${done[0]}</button>` : ""}</div>`;
    if (done) $("#dn").onclick = done[1];
  };
  const onKey = (event) => {
    if (!document.body.contains(el)) return document.removeEventListener("keydown", onKey);
    if (event.key === " " && !flipped && index < queue.length) {
      event.preventDefault();
      flip();
    } else if (flipped && /^[1-4]$/.test(event.key)) {
      rate(Number(event.key));
    }
  };
  document.addEventListener("keydown", onKey);
  draw();
}

export function viewReview(el) {
  el.innerHTML = '<h2 style="margin-bottom:14px">Review</h2><div id="rv"></div>';
  reviewSession($("#rv"), dueCards(book.chapters, store, now()), "Whole book", ["Back to chapters", () => go("home")]);
}
