// Shared state for the study site: the book, saved progress, and navigation.

const EMPTY_BOOK = { title: "No book yet", chapters: [], graph: { nodes: [], edges: [], layers: [], tour: [] } };

export const book = window.BOOK || EMPTY_BOOK;
const storageKey = `nlbook:${book.title || "book"}`;

function loadStore() {
  let saved = {};
  try {
    saved = JSON.parse(localStorage.getItem(storageKey)) || {};
  } catch {
    saved = {};
  }
  return { cards: {}, quiz: {}, loop: {}, recall: {}, remake: {}, mapPos: {}, mapSeen: [], ...saved };
}

export const store = loadStore();

/** Save progress locally, and tell the NeuralLoop desktop app when the site runs inside it. */
export function persist() {
  try {
    localStorage.setItem(storageKey, JSON.stringify(store));
  } catch {
    // Private browsing or a full disk: progress stays in memory for this session.
  }
  if (window.parent !== window) window.parent.postMessage({ type: "nl-progress", data: store }, "*");
}

export const now = () => Date.now();

let renderPage = () => {};
export let route = { view: "home" };

export function setRenderer(render) {
  renderPage = render;
}

export function go(view, params = {}) {
  route = { view, ...params };
  renderPage();
  window.scrollTo({ top: 0 });
}

export function rerender() {
  renderPage();
}

export const chapterByNumber = (n) => book.chapters.find((c) => c.n === n);
