// The study shelf: Pip's greeting, setup checklist, book cards, and adding books.

import { $, $$, esc, openSheet, pip, toast } from "./dom.js";
import { friendlyError, isValidMediaSpec, pipGreeting, setupSteps, statusPills } from "./logic.js";
import { app, go } from "./state.js";
import { invoke, pickFile } from "./tauri.js";

const COVER_COLORS = ["#E0683F", "#5C86E0", "#3FA88A", "#8A6FE0", "#E0A52A", "#E2577E", "#2FA6B8"];
const VIDEO_STYLES = [
  ["kawaii", "Kawaii"],
  ["whiteboard", "Whiteboard"],
  ["watercolor", "Watercolor"],
  ["classic", "Classic"],
  ["paper-craft", "Paper craft"],
  ["anime", "Anime"],
];
const PODCAST_STYLES = [
  ["deep-dive", "Deep dive"],
  ["brief", "Brief"],
  ["debate", "Debate"],
  ["critique", "Critique"],
];
const LANGUAGES = [
  ["en", "English"],
  ["hi", "Hindi"],
  ["es", "Spanish"],
  ["fr", "French"],
  ["de", "German"],
];
const POLL_MS = 4000;
let pollTimer;

export async function refreshBooks() {
  app.books = await invoke("list_books");
  if (app.view.name === "library") drawLibrary();
  clearTimeout(pollTimer);
  if (app.books.some((book) => book.running)) pollTimer = setTimeout(refreshBooks, POLL_MS);
}

export async function viewLibrary() {
  $("#main").innerHTML = '<div class="wrap" id="lib"></div>';
  drawLibrary();
  refreshBooks();
  if (!app.setup) {
    app.setup = await invoke("check_setup");
    drawLibrary();
  }
}

function setupChecklist() {
  const steps = setupSteps(app.setup);
  if (!steps.length) return "";
  const items = steps.map((step) => `<li class="${step.ok ? "ok" : ""}">${esc(step.ok ? step.done : step.todo)}</li>`).join("");
  return `<div class="setup"><b>A few things before Pip can make your first book</b><ol>${items}</ol>
    <div class="row" style="margin-top:10px"><button class="btn sm" id="recheck">Check again</button>
    ${app.setup.python ? '<button class="btn ghost sm" id="trysample">Try the sample book (no Google needed)</button>' : ""}</div></div>`;
}

function bookCard(book, index) {
  const pose = book.running ? "study" : book.loopsClosed ? "proud" : "read";
  const pills = statusPills(book)
    .map((p) => `<span class="pill p-${p.kind}">${p.spinner ? '<span class="spin"></span>' : ""}${esc(p.text)}</span>`)
    .join("");
  const log = book.running && app.logs[book.id] ? `<div class="log">${esc(app.logs[book.id].slice(-4).join("\n"))}</div>` : "";
  return `<article class="book">
    <div class="cover" style="background:${COVER_COLORS[index % COVER_COLORS.length]}"><span class="pipmini pip moving">${(window.PIP || {})[pose] || ""}</span><span class="cover-title">${esc(book.title)}</span></div>
    <div class="tiny">${book.chapters} chapters · ${book.loopsClosed}/${book.chapters} loops closed</div>
    <div class="pills">${pills}</div>${log}
    <div class="row" style="margin-top:auto">
      <button class="btn sm" data-open="${book.id}" ${book.ready ? "" : "disabled"}>Study</button>
      ${book.running ? `<button class="btn ghost sm" data-stop="${book.id}">Pause</button>` : `<button class="btn ghost sm" data-more="${book.id}">Prepare more</button>`}
      <button class="btn ghost sm" data-del="${book.id}" aria-label="Remove ${esc(book.title)}">Remove</button></div></article>`;
}

function drawLibrary() {
  const el = $("#lib");
  if (!el) return;
  const { pose, line } = pipGreeting(app.books);
  el.innerHTML = `<section class="hero"><div><h1>Your study shelf</h1><div class="bubble">${esc(line)}</div>
      <div class="row"><button class="btn" id="addbook">Add a book</button><span class="tiny">PDF or EPUB. Pip prepares videos, podcasts, quizzes, flashcards, and maps.</span></div></div>
      ${pip(pose, "pipbig")}</section>
    ${setupChecklist()}
    <div class="books">${app.books.map(bookCard).join("")}
      <button class="addcard" id="addbook2"><span class="plus">+</span><b>Add a book</b><span class="tiny">PDF or EPUB</span></button></div>`;
  $("#addbook").onclick = pickBook;
  $("#addbook2").onclick = pickBook;
  if ($("#recheck")) {
    $("#recheck").onclick = async () => {
      app.setup = await invoke("check_setup");
      drawLibrary();
      toast("Checked");
    };
  }
  if ($("#trysample")) $("#trysample").onclick = startSample;
  $$("[data-open]").forEach((b) => {
    b.onclick = () => go("book", { id: b.dataset.open });
  });
  $$("[data-stop]").forEach((b) => {
    b.onclick = async () => {
      await invoke("cancel_pipeline", { bookId: b.dataset.stop });
      toast("Paused. Prepare more to continue later.");
    };
  });
  $$("[data-more]").forEach((b) => {
    b.onclick = () => optionsSheet({ bookId: b.dataset.more, title: app.books.find((x) => x.id === b.dataset.more)?.title });
  });
  $$("[data-del]").forEach((b) => {
    b.onclick = () => confirmRemove(b.dataset.del);
  });
}

export async function pickBook() {
  const path = await pickFile([{ name: "Books", extensions: ["pdf", "epub"] }]);
  if (path) optionsSheet({ path, title: String(path).split(/[\\/]/).pop() });
}

const selectOptions = (choices, chosen) =>
  choices.map(([value, label]) => `<option value="${value}" ${value === chosen ? "selected" : ""}>${label}</option>`).join("");

function optionsSheet({ path, bookId, title }) {
  const previous = bookId ? app.books.find((b) => b.id === bookId)?.options || {} : {};
  let style = previous.style || "kawaii";
  openSheet(
    `<h2>${bookId ? "Prepare more" : "Add a book"}</h2><p class="muted small">${esc(title || "")}</p>
    <label class="field"><b>Podcast + video for chapters</b><input type="text" id="media" value="${esc(previous.media || "1-2")}" aria-describedby="mh">
      <span class="tiny" id="mh">Like 1-2, 1-5, 1,4,7, all, or none. Every chapter still gets its reading guide, recall, quiz, flashcards, and maps. Videos and podcasts are slow and NotebookLM limits them per day, so start small.</span></label>
    <div class="field"><b>Video style</b><div class="stylegrid">${VIDEO_STYLES.map(([id, label]) => `<button data-style="${id}" aria-pressed="${id === style}">${label}</button>`).join("")}</div></div>
    <label class="field"><b>Podcast style</b><select id="audio">${selectOptions(PODCAST_STYLES, previous.audio || "deep-dive")}</select></label>
    <label class="field"><b>Language</b><select id="lang">${selectOptions(LANGUAGES, previous.language || "en")}</select></label>
    <label class="check"><input type="checkbox" id="dry" ${previous.dryRun ? "checked" : ""}><span class="small">Practice run without Google (Pip makes pretend materials so you can try the app)</span></label>
    ${bookId ? '<label class="check"><input type="checkbox" id="retry" checked><span class="small">Also retry anything that failed or hit NotebookLM\'s limit</span></label>' : ""}
    <p class="tiny" style="margin-top:12px">The book is sent to Google NotebookLM with your account. Use books you own.</p>
    <div class="row" style="margin-top:14px"><button class="btn" id="go">${bookId ? "Prepare" : "Start"}</button><button class="btn ghost" id="cancel">Cancel</button></div>`,
    (root, close) => {
      $$("[data-style]", root).forEach((button) => {
        button.onclick = () => {
          style = button.dataset.style;
          $$("[data-style]", root).forEach((b) => b.setAttribute("aria-pressed", b === button));
        };
      });
      $("#cancel", root).onclick = close;
      $("#go", root).onclick = async () => {
        const media = $("#media", root).value.trim() || "1-2";
        if (!isValidMediaSpec(media)) return toast('Use numbers like 1-2 or 1,4,7, or "all" / "none"');
        const opts = {
          path: path || null,
          bookId: bookId || null,
          media,
          style,
          video: "explainer",
          audio: $("#audio", root).value,
          language: $("#lang", root).value,
          dryRun: $("#dry", root).checked,
          retry: Boolean($("#retry", root)?.checked),
        };
        try {
          const id = await invoke("start_pipeline", { opts });
          app.logs[id] = ["Pip is opening the book…"];
          close();
          toast("Pip is on it!");
          refreshBooks();
        } catch (error) {
          toast(friendlyError(error));
        }
      };
    },
  );
}

async function startSample() {
  if (!app.setup?.samplePath) return pickBook();
  try {
    const id = await invoke("start_pipeline", {
      opts: {
        path: app.setup.samplePath,
        bookId: null,
        media: "1-2",
        style: "kawaii",
        audio: "deep-dive",
        video: "explainer",
        language: "en",
        dryRun: true,
        retry: false,
      },
    });
    app.logs[id] = ["Opening the sample book…"];
    refreshBooks();
  } catch (error) {
    toast(friendlyError(error));
  }
}

function confirmRemove(id) {
  const book = app.books.find((b) => b.id === id);
  openSheet(
    `<h2>Remove “${esc(book.title)}”?</h2><p class="muted">This removes the prepared materials and your progress for this book from NeuralLoop. Your original file isn't touched.</p>
    <div class="row" style="margin-top:14px"><button class="btn danger" id="yes">Remove</button><button class="btn ghost" id="no">Keep it</button></div>`,
    (root, close) => {
      $("#no", root).onclick = close;
      $("#yes", root).onclick = async () => {
        await invoke("delete_book", { bookId: id });
        close();
        refreshBooks();
      };
    },
  );
}
