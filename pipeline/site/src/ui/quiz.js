// Multiple-choice quiz: one question at a time, hints, explanations, and a score.

import { persist, store } from "./context.js";
import { $, $$, confetti, esc, pip, pipAside } from "./dom.js";

const LETTERS = "ABCDEF";

/** `onDone` is [label, callback] for the button on the score screen. */
export function renderQuiz(el, chapter, onDone) {
  const questions = chapter.quiz || [];
  store.quiz[chapter.n] ??= { i: 0, results: [] };
  const progress = store.quiz[chapter.n];
  if (progress.i >= questions.length) return scoreScreen(el, chapter, onDone);

  const q = questions[progress.i];
  const bar = questions
    .map(
      (_, i) =>
        `<i class="${i < progress.i ? (progress.results[i] ? "right" : "wrong") : i === progress.i ? "now" : ""}"></i>`,
    )
    .join("");
  el.innerHTML = `<div class="pane with-pip"><div class="qwrap">
    <div class="qprog">${bar}</div>
    <div class="qcard"><p class="tiny" style="margin:0 0 6px">Question ${progress.i + 1} of ${questions.length}</p><h3>${esc(q.q)}</h3>
      ${q.options.map((option, i) => `<button class="opt" data-o="${i}"><span class="let">${LETTERS[i]}</span><span>${esc(option)}<span class="why" hidden></span></span></button>`).join("")}
      <div class="row" style="margin-top:14px">${q.hint ? '<button class="btn ghost sm" id="hintb">Show a hint</button>' : ""}</div>
      <div id="hintbox"></div><div id="next" style="margin-top:14px"></div></div>
  </div>${pipAside("read", "Take your time. Guessing and checking is how memory grows.")}</div>`;

  if (q.hint) {
    $("#hintb").onclick = () => {
      $("#hintbox").innerHTML = `<div class="hint">💡 ${esc(q.hint)}</div>`;
      $("#hintb").remove();
    };
  }
  $$(".opt", el).forEach((button) => {
    button.onclick = () => answer(el, chapter, onDone, q, Number(button.dataset.o));
  });
}

function answer(el, chapter, onDone, q, picked) {
  const progress = store.quiz[chapter.n];
  const correct = picked === q.a;
  $$(".opt", el).forEach((button) => {
    const i = Number(button.dataset.o);
    button.disabled = true;
    if (i === q.a) button.classList.add("right");
    else if (i === picked) button.classList.add("wrong");
    const why = button.querySelector(".why");
    if ((i === q.a || i === picked) && q.why?.[i]) {
      why.textContent = q.why[i];
      why.hidden = false;
    }
  });
  progress.results[progress.i] = correct;
  persist();
  const aside = $(".pipside", el);
  if (aside)
    aside.innerHTML = `<div class="bubble">${correct ? "Yes! Exactly right." : "Close! The right one is highlighted."}</div>${pip(correct ? "hop" : "read")}`;
  const last = progress.i + 1 >= (chapter.quiz || []).length;
  $("#next").innerHTML = `<button class="btn" id="nb">${last ? "See my score" : "Next question"}</button>`;
  $("#nb").onclick = () => {
    progress.i += 1;
    persist();
    renderQuiz(el, chapter, onDone);
  };
  $("#nb").focus();
}

function scoreScreen(el, chapter, onDone) {
  const questions = chapter.quiz || [];
  const progress = store.quiz[chapter.n];
  const right = progress.results.filter(Boolean).length;
  const great = right >= Math.ceil(questions.length * 0.8);
  el.innerHTML = `<div class="qwrap"><div class="card empty">${pip(great ? "proud" : "hug", "pipmid")}
    <h3>${right} of ${questions.length} right</h3>
    <p class="muted">${great ? "Wonderful! That chapter's really sinking in." : "Nice work. The ones you missed are great flashcard material."}</p>
    <div class="row" style="justify-content:center;margin-top:10px">
      ${onDone ? `<button class="btn" id="qdone">${onDone[0]}</button>` : ""}<button class="btn ghost" id="again">Try again</button></div></div></div>`;
  if (great) confetti();
  $("#again").onclick = () => {
    store.quiz[chapter.n] = { i: 0, results: [] };
    persist();
    renderQuiz(el, chapter, onDone);
  };
  if (onDone) $("#qdone").onclick = onDone[1];
}
