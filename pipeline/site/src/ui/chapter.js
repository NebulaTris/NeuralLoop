// One chapter's learning loop: the step bar, the current step, and the loop-closed celebration.

import { STAGES, completeStage, isUnlocked, loopOf, nextStage } from "../core/loop.js";
import { book, go, now, persist, rerender, route, store } from "./context.js";
import { $, $$, confetti, esc, pip, toast } from "./dom.js";
import { STAGE_VIEWS } from "./stages.js";

export function viewChapter(el) {
  const chapter = book.chapters.find((c) => c.n === route.n);
  if (!chapter) return go("home");
  if (!isUnlocked(store, book.chapters, chapter.n)) return lockedChapter(el, chapter);

  const loop = loopOf(store, chapter.n);
  route.stage ||= nextStage(store, chapter.n) || "prime";
  store.last = { n: chapter.n, stage: route.stage };
  persist();

  el.innerHTML = `<button class="back" id="back">‹ All chapters</button>
    <div class="chapter-head"><span class="bignum">${chapter.n}</span><h2>${esc(chapter.title)}</h2></div>
    <nav class="stepper" aria-label="Loop steps">${STAGES.map(
      (stage, i) => `
      <button data-stage="${stage.id}" class="${loop[stage.id] ? "done" : ""}" ${stage.id === route.stage ? 'aria-current="step"' : ""}>
        <span class="n">${loop[stage.id] ? "✓" : i + 1}</span>${stage.label}<small>${stage.verb}</small></button>`,
    ).join("")}</nav>
    <div id="stagebody"></div><div class="foot" id="foot"></div>`;
  $("#back").onclick = () => go("home");
  $$("[data-stage]", el).forEach((button) => {
    button.onclick = () => {
      route.stage = button.dataset.stage;
      rerender();
    };
  });

  const nextStep = STAGES[STAGES.findIndex((s) => s.id === route.stage) + 1];
  const showFinishButton = (label) => {
    $("#foot").innerHTML = `<button class="btn" id="fin">${label}</button>`;
    $("#fin").onclick = () => {
      finishStage(chapter.n, route.stage);
      if (nextStep && route.view === "chapter") {
        route.stage = nextStep.id;
        rerender();
      }
    };
  };
  STAGE_VIEWS[route.stage]($("#stagebody"), chapter, showFinishButton);
}

/** Mark a step done, tell the reader what changed, and celebrate a closed loop. */
export function finishStage(n, stageId) {
  const alreadyDone = Boolean(loopOf(store, n)[stageId]);
  const closedNow = completeStage(store, n, stageId, now());
  persist();
  if (!alreadyDone) {
    const ideas = book.graph.nodes.filter((node) => node.chapter === n).length;
    toast(
      stageId === "map" && ideas
        ? `🌱 ${ideas} new ideas joined your book map`
        : `${STAGES.find((s) => s.id === stageId).label} done`,
    );
  }
  if (closedNow) celebrate(n);
}

function lockedChapter(el, chapter) {
  const previous = book.chapters[book.chapters.findIndex((c) => c.n === chapter.n) - 1];
  el.innerHTML = `<button class="back" id="back">‹ All chapters</button>
    <div class="card empty" style="margin-top:14px">${pip("nap", "pipmid")}<h3>Chapter ${chapter.n} is still locked</h3>
      <p class="muted">Close the loop for chapter ${previous.n}, “${esc(previous.title)}”, and this one unlocks. One chapter at a time is how it sticks.</p>
      <button class="btn" id="goprev">Go to chapter ${previous.n}</button></div>`;
  $("#back").onclick = () => go("home");
  $("#goprev").onclick = () => go("chapter", { n: previous.n });
}

function celebrate(n) {
  const index = book.chapters.findIndex((c) => c.n === n);
  const chapter = book.chapters[index];
  const next = book.chapters[index + 1];
  const modal = document.createElement("div");
  modal.className = "modal";
  modal.innerHTML = `<div class="card">${pip("hug", "pipmid")}<h3>Loop closed!</h3>
    <p class="muted">You listened, read, recalled, remade the map, and reviewed "${esc(chapter.title)}".
      Your flashcards will come back right before you'd forget them.</p>
    ${next ? `<p><b>🔓 Chapter ${next.n}, “${esc(next.title)}”, is unlocked!</b></p>` : "<p><b>🎉 That was the last chapter. You finished the whole book!</b></p>"}
    <div class="row" style="justify-content:center">
      ${next ? `<button class="btn" id="mnext">Start chapter ${next.n}</button>` : ""}
      <button class="btn ${next ? "ghost" : ""}" id="mok">${next ? "Later" : "Yay!"}</button></div></div>`;
  document.body.appendChild(modal);
  confetti();
  $("#mok", modal).onclick = () => {
    modal.remove();
    go("home");
  };
  if (next) {
    $("#mnext", modal).onclick = () => {
      modal.remove();
      go("chapter", { n: next.n });
    };
  }
  ($("#mnext", modal) || $("#mok", modal)).focus();
}
