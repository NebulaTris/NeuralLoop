// The chapter shelf: progress, resume card, and one card per chapter (locked until earned).

import { wireYearLog, yearLogCard } from "./yearlog.js";
import { dueCards, unlockedCards } from "../core/cards.js";
import { STAGES, isMapped, isUnlocked, loopOf, nextStage } from "../core/loop.js";
import { book, go, now, store } from "./context.js";
import { $, $$, ICONS, esc, pip, statusOf, toast } from "./dom.js";

const MATERIALS = [
  ["video", "Video"],
  ["audio", "Podcast"],
  ["study", "Reading guide and recall prompts"],
  ["quiz", "Quiz"],
  ["cards", "Flashcards"],
  ["mindmap", "Mind map"],
  ["graph", "Concept graph"],
];

export function viewHome(el) {
  const chapters = book.chapters;
  const due = dueCards(chapters, store, now()).length;
  const working = chapters.some((c) => Object.values(c.status).includes("working"));
  const closed = chapters.filter((c) => !nextStage(store, c.n)).length;
  const ideas = book.graph.nodes.filter((node) => isMapped(store, node.chapter)).length;
  const last = store.last && chapters.find((c) => c.n === store.last.n);
  const lastNext = last && nextStage(store, last.n);
  const pose = working ? "study" : closed && closed === chapters.length ? "proud" : due ? "play" : "read";

  el.innerHTML = `
    <section class="hero"><div>
      <p class="muted">${esc(book.source || "")}${book.dryRun ? " · dry run" : ""}</p>
      <h2>${esc(book.title)}</h2>
      <p class="muted" style="max-width:58ch">Each chapter is a small loop: listen first, read with a guide, recall it in your own words,
        remake the map from memory, then review. ${working ? "Pip is still making some materials; this page updates by itself." : ""}</p>
      <div class="stats">
        ${stat(`${closed}/${chapters.length}`, "loops closed")}
        ${stat(chapters.filter((c) => c.status.video === "done").length, "videos")}
        ${stat(unlockedCards(chapters, store).length, "flashcards")}
        ${stat(ideas, "ideas in your map")}
      </div>
      ${last && lastNext ? resumeCard(last, lastNext) : ""}
      <div class="row" style="margin-top:14px">
        ${due ? `<button class="btn" id="goreview">Review ${due} card${due > 1 ? "s" : ""}</button>` : ""}
        <button class="btn ghost" id="gomap">Explore the book map</button>
      </div>
    </div>${pip(pose, "pipbig")}</section>
    <div class="grid">${chapters.map((chapter, i) => chapterCard(chapter, chapters[i - 1])).join("")}</div>
    ${yearLogCard()}`;
  wireYearLog(el);

  $$("[data-ch]", el).forEach((card) => {
    card.onclick = () =>
      card.dataset.locked
        ? toast(`Close chapter ${card.dataset.locked}'s loop first. Pip is saving this one for you.`)
        : go("chapter", { n: Number(card.dataset.ch) });
  });
  if (last && lastNext) $("#resume").onclick = () => go("chapter", { n: last.n, stage: lastNext });
  if (due) $("#goreview").onclick = () => go("review");
  $("#gomap").onclick = () => go("map");
}

const stat = (value, label) => `<div class="stat"><b>${value}</b><span class="tiny">${label}</span></div>`;

function resumeCard(chapter, stageId) {
  const stage = STAGES.find((s) => s.id === stageId);
  return `<button class="resume" id="resume"><div>
    <span>Pick up where you left off · Chapter ${chapter.n}</span><b>${esc(chapter.title)}</b><span>Next: ${stage.verb}</span>
  </div></button>`;
}

function chapterCard(chapter, previous) {
  const loop = loopOf(store, chapter.n);
  const open = isUnlocked(store, book.chapters, chapter.n);
  const dots = STAGES.map((s) => `<b class="${loop[s.id] ? "on" : ""}" title="${s.label}"></b>`).join("");
  const icons = MATERIALS.map(
    ([kind, label]) =>
      `<span class="ico ${chapter.status[kind]}" title="${label}: ${statusOf(chapter.status[kind]).label}">${ICONS[kind]}</span>`,
  ).join("");
  return `<button class="ch ${open ? "" : "locked"}" data-ch="${chapter.n}" ${open ? "" : `aria-disabled="true" data-locked="${previous.n}"`}>
    <div class="row" style="justify-content:space-between"><span class="num">${chapter.n}</span>
      <span class="loopdots" aria-label="${STAGES.filter((s) => loop[s.id]).length} of 5 loop steps done">${dots}</span></div>
    <h3>${esc(chapter.title)}</h3>
    ${open ? "" : `<span class="lockline">🔒 Finish chapter ${previous.n}'s loop to unlock</span>`}
    <div class="icons">${icons}</div></button>`;
}
