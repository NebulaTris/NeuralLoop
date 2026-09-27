// The five steps of a chapter's loop. Each takes (container, chapter, showFinishButton).

import { isMapped } from "../core/loop.js";
import { compareRemake, recallScore } from "../core/recall.js";
import { levelLabel, markdownToHtml, withoutRepeatedTitle } from "../core/text.js";
import { finishStage } from "./chapter.js";
import { persist, rerender, route, store } from "./context.js";
import { $, $$, confetti, esc, notReady, pip, pipAside, statusOf, toast } from "./dom.js";
import { reviewSession } from "./flashcards.js";
import { renderChapterGraph } from "./graph.js";
import { renderMindMap } from "./mindmap.js";
import { renderQuiz } from "./quiz.js";

function listenAndWatch(el, chapter, showFinish) {
  const hasVideo = chapter.status.video === "done";
  const hasAudio = chapter.status.audio === "done";
  const placeholder = (kind) => {
    const status = chapter.status[kind];
    const hint =
      {
        skipped: chapter.notes[kind] || `Add it with --media ${chapter.n}`,
        waiting_quota: "Waiting for NotebookLM's daily limit",
        working: "Pip is making it now",
      }[status] || "";
    return `<div class="card empty" style="padding:18px"><span class="pill ${statusOf(status).pill}">${statusOf(status).label}</span><p class="tiny" style="margin-top:6px">${esc(hint)}</p></div>`;
  };
  el.innerHTML = `<p class="small muted" style="margin:0 0 12px">Watch the video, then play the podcast on a walk. Hearing the ideas first makes the chapter feel familiar when you read it.</p>
    <div class="lw">
      <section><h3 style="margin-bottom:8px">🎬 Watch</h3>${hasVideo ? `<div class="card" style="padding:10px"><video class="media" controls preload="metadata" src="${esc(chapter.video)}"></video></div>` : placeholder("video")}</section>
      <section><h3 style="margin-bottom:8px">🎧 Listen</h3>${hasAudio ? `<div class="card"><p class="small muted" style="margin:0 0 8px">Two hosts talk it through.</p><audio controls preload="metadata" style="width:100%" src="${esc(chapter.audio)}"></audio></div>` : placeholder("audio")}
        <div style="max-width:220px;margin:14px auto 0">${pip(hasVideo ? "read" : "nap")}</div></section>
    </div>`;
  showFinish("Done watching and listening · start reading");
}

function read(el, chapter, showFinish) {
  const guide = chapter.status.study === "done" ? chapter.guide || [] : [];
  const plan = guide.length
    ? `<div class="card" style="margin-bottom:14px"><h3 style="margin-bottom:8px">Your reading plan</h3><div class="plan">${guide
        .map(
          (entry) =>
            `<div><span class="pill ${levelLabel(entry.level).pill}" style="flex:none">${levelLabel(entry.level).label}</span><span class="small"><b>${esc(entry.section)}</b>: ${esc(entry.why)}</span></div>`,
        )
        .join("")}</div></div>`
    : `<p class="small muted">${chapter.status.study === "working" ? "Pip is writing your reading plan…" : "No reading plan for this chapter yet."}</p>`;
  const source = chapter.read;
  let body;
  if (!source)
    body = '<div class="card empty"><p class="muted">The chapter file wasn\'t found next to this page.</p></div>';
  else if (source.kind === "pdf")
    body = `<iframe class="pdf" src="${esc(source.file)}" title="Chapter ${chapter.n}"></iframe><p class="tiny">If the chapter doesn't show here, <a href="${esc(source.file)}" target="_blank">open it in a new tab</a>.</p>`;
  else
    body = `<article class="card reader">${markdownToHtml(withoutRepeatedTitle(source.text, chapter.title), guide)}</article>`;
  el.innerHTML = plan + body;
  showFinish("I've finished reading · recall it");
}

function recall(el, chapter, showFinish) {
  const prompts = chapter.status.study === "done" ? chapter.recall || [] : [];
  store.recall[chapter.n] ??= { i: 0, scores: [] };
  const progress = store.recall[chapter.n];
  const quizReady = chapter.status.quiz === "done";
  const toMap = () => {
    finishStage(chapter.n, "recall");
    route.stage = "map";
    rerender();
  };

  if (progress.i < prompts.length) return recallPrompt(el, chapter, showFinish, prompts, progress, quizReady);
  if (quizReady) return renderQuiz(el, chapter, ["Continue to the map", toMap]);
  el.innerHTML = prompts.length
    ? `<div class="card empty">${pip("proud", "pipmid")}<h3>Recall done</h3></div>`
    : notReady(chapter, "study");
  showFinish("Continue to the map");
}

function recallPrompt(el, chapter, showFinish, prompts, progress, quizReady) {
  const prompt = prompts[progress.i];
  el.innerHTML = `<div class="pane with-pip"><div class="qwrap"><div class="qcard">
      <p class="tiny" style="margin:0 0 6px">In your own words · ${progress.i + 1} of ${prompts.length}</p><h3>${esc(prompt.prompt)}</h3>
      <textarea id="ans" placeholder="Explain it like you're telling a teammate. A rough attempt counts."></textarea>
      <div class="row" style="margin-top:10px"><button class="btn" id="chk">Check myself</button><button class="btn ghost sm" id="skip">Skip</button></div>
      <div id="kps"></div></div></div>${pipAside("read", "Struggling a little is what makes it stick. Write before you peek.")}</div>`;
  const answer = $("#ans");
  const next = () => {
    progress.i += 1;
    progress.draft = "";
    persist();
    recall(el, chapter, showFinish);
  };
  answer.value = progress.draft || "";
  answer.oninput = () => {
    progress.draft = answer.value;
    persist();
  };
  $("#skip").onclick = () => {
    progress.scores[progress.i] = null;
    next();
  };
  $("#chk").onclick = () => {
    if (answer.value.trim().length < 15) return toast("Write a sentence or two first");
    $("#chk").disabled = true;
    $("#kps").innerHTML = `<p class="small" style="margin:14px 0 4px"><b>Tick what your answer covered</b></p>
      ${prompt.keyPoints.map((point, i) => `<label class="kp"><input type="checkbox" data-kp="${i}"><span>${esc(point)}</span></label>`).join("")}
      <button class="btn" id="scr" style="margin-top:12px">Score it</button>`;
    $("#scr").onclick = () => {
      const covered = $$("[data-kp]").filter((box) => box.checked).length;
      const score = recallScore(covered, prompt.keyPoints.length);
      progress.scores[progress.i] = score;
      persist();
      const lastPrompt = progress.i + 1 >= prompts.length;
      $("#kps").innerHTML =
        `<div class="row" style="margin-top:14px"><b>Score</b><span class="score">${[1, 2, 3].map((n) => `<i class="${n <= score ? "on" : ""}"></i>`).join("")}</span><span class="small muted">${score}/3</span></div>
        <p class="small muted">${score === 3 ? "You explained it fully. That's real understanding." : "The points you missed are worth a second look in the reading."}</p>
        <button class="btn" id="nx">${lastPrompt ? (quizReady ? "On to the quiz" : "Continue") : "Next question"}</button>`;
      const aside = $(".pipside", el);
      if (aside)
        aside.innerHTML = `<div class="bubble">${score >= 2 ? "Look at you go!" : "Nice try. Every attempt helps."}</div>${pip(score >= 2 ? "hop" : "read")}`;
      $("#nx").onclick = next;
    };
  };
}

function map(el, chapter, showFinish) {
  const hasMindMap = chapter.status.mindmap === "done";
  const hasGraph = chapter.status.graph === "done";
  const mode = route.mapMode || (hasMindMap ? (isMapped(store, chapter.n) ? "mind" : "remake") : "concepts");
  const tab = (id, label) => `<button data-mm="${id}" aria-pressed="${mode === id}">${label}</button>`;
  el.innerHTML = `<div class="seg" role="group" aria-label="Map view" style="margin-bottom:14px">
      ${hasMindMap ? tab("remake", "Remake from memory") + tab("mind", "Mind map") : ""}${hasGraph ? tab("concepts", "Concept graph") : ""}</div>
    <div id="mapbody"></div>`;
  $$("[data-mm]", el).forEach((button) => {
    button.onclick = () => {
      route.mapMode = button.dataset.mm;
      map(el, chapter, showFinish);
    };
  });
  const body = $("#mapbody", el);
  if (!hasMindMap && !hasGraph) {
    body.innerHTML = notReady(chapter, "mindmap");
    return showFinish("Skip to flashcards");
  }
  if (mode === "remake") {
    remake(body, chapter, () => {
      route.mapMode = "mind";
      finishStage(chapter.n, "map");
      map(el, chapter, showFinish);
    });
  } else if (mode === "mind") {
    renderMindMap(body, chapter.mindmap);
  } else {
    renderChapterGraph(body, chapter);
  }
  showFinish(isMapped(store, chapter.n) ? "Continue to flashcards" : "I've got the big picture · flashcards");
}

function remake(el, chapter, onSeeFullMap) {
  const mindMap = chapter.mindmap || { name: chapter.title, children: [] };
  store.remake[chapter.n] ??= {};
  const saved = store.remake[chapter.n];
  el.innerHTML = `<div class="pane with-pip"><div class="card">
    <h3 style="margin-bottom:6px">Remake the map from memory</h3>
    <p class="small muted">Before you look: write the main branches of "${esc(mindMap.name)}" as you remember them, one per line. Add sub-ideas under a branch by starting the line with a dash.</p>
    <textarea id="guess" placeholder="Foundations&#10;- key terms&#10;In practice&#10;- failure modes">${esc(saved.guess || "")}</textarea>
    <div class="row" style="margin-top:10px"><button class="btn" id="cmp">Compare with the real map</button></div><div id="cres"></div></div>
    ${pipAside("play", "No peeking! Pulling it out of your head is the whole trick.")}</div>`;
  $("#guess").oninput = (event) => {
    saved.guess = event.target.value;
    persist();
  };
  $("#cmp").onclick = () => {
    const result = compareRemake($("#guess").value, mindMap);
    if (!result.lines.length) return toast("Write at least one branch first");
    saved.best = Math.max(saved.best || 0, result.percent);
    persist();
    const rows = result.rows
      .map(
        (row) =>
          `<div class="branch ${row.remembered ? "hit" : "miss"}">${row.remembered ? "✓ " : ""}${esc(row.name)}${row.children.map((child) => `<small>${child.remembered ? "✓" : "·"} ${esc(child.name)}</small>`).join("")}</div>`,
      )
      .join("");
    const good = result.percent >= 70;
    $("#cres").innerHTML = `<div class="remake" style="margin-top:14px">
      <div><p class="small"><b>The real map</b> (green = you remembered it)</p>${rows}</div>
      <div><p class="small"><b>Your version</b></p>${result.lines.map((line) => `<div class="branch" style="background:var(--sunk)">${esc(line)}</div>`).join("")}
        <p style="margin-top:12px"><b style="font-family:var(--display);font-size:1.6rem">${result.percent}%</b> <span class="small muted">remembered${saved.best > result.percent ? ` · best ${saved.best}%` : ""}</span></p>
        <p class="small muted">${good ? "Brilliant. You can sketch this chapter from memory." : "Look at the grey branches, then try again tomorrow. It gets easier every time."}</p>
        <div class="row"><button class="btn" id="seefull">See the full map</button><button class="btn ghost sm" id="again">Try again</button></div></div></div>`;
    if (good) confetti();
    const aside = $(".pipside", el);
    if (aside)
      aside.innerHTML = `<div class="bubble">${good ? "You remembered so much!" : "Good effort. Grey means 'look again'."}</div>${pip(good ? "proud" : "hug")}`;
    $("#seefull").onclick = onSeeFullMap;
    $("#again").onclick = () => {
      saved.guess = "";
      persist();
      remake(el, chapter, onSeeFullMap);
    };
  };
}

function remember(el, chapter, showFinish) {
  if (chapter.status.cards !== "done") {
    el.innerHTML = notReady(chapter, "cards");
    return showFinish("Finish this loop");
  }
  const cards = (chapter.cards || []).map((card, i) => ({ ...card, id: `${chapter.n}:${i}` }));
  reviewSession(el, cards, `Chapter ${chapter.n}`, [
    "Finish this loop",
    () => {
      finishStage(chapter.n, "space");
      rerender();
    },
  ]);
}

export const STAGE_VIEWS = { prime: listenAndWatch, read, recall, map, space: remember };
