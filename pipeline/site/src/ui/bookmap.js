// The book map: grows with every chapter whose Map step is done.

import { isMapped, isUnlocked } from "../core/loop.js";
import { book, go, persist, store } from "./context.js";
import { $, PALETTE, pip } from "./dom.js";
import { mountGraph } from "./graph.js";

export function viewBookMap(el) {
  const ideaCount = (n) => book.graph.nodes.filter((node) => node.chapter === n).length;
  const earned = book.chapters.filter((c) => isMapped(store, c.n) && ideaCount(c.n)).map((c) => c.n);
  el.innerHTML = `<h2>Book map</h2>
    <p class="muted" style="margin:6px 0 12px">Your map of the book grows with every chapter you map. Dashed lines join the same idea across chapters; pink dotted lines show disagreements.</p>
    <div class="growstrip" id="strip"></div><div id="gm"></div>`;

  const chips = book.chapters.map((c) => {
    if (earned.includes(c.n)) {
      return `<span class="gchip"><i style="background:${PALETTE[earned.indexOf(c.n) % PALETTE.length]}"></i>🌱 Chapter ${c.n} · ${ideaCount(c.n)} ideas</span>`;
    }
    return `<span class="gchip future">${isUnlocked(store, book.chapters, c.n) ? "🌰" : "🔒"} Chapter ${c.n}</span>`;
  });
  $("#strip").innerHTML =
    chips.join("") + (earned.length > 1 ? '<button class="btn ghost sm" id="replay">▶ Replay growth</button>' : "");

  if (!earned.length) {
    const first = book.chapters.find((c) => !isMapped(store, c.n)) || book.chapters[0];
    $("#gm").innerHTML = `<div class="card empty">${pip("play", "pipmid")}<h3>Your map is a tiny seed</h3>
      <p class="muted">Finish chapter ${first.n}'s Map step and its ideas will sprout here. Every chapter after that makes the map bigger.</p>
      <button class="btn" id="plant">Go to chapter ${first.n}</button></div>`;
    $("#plant").onclick = () => go("chapter", { n: first.n, stage: "map" });
    return;
  }

  const ids = new Set(book.graph.nodes.filter((node) => earned.includes(node.chapter)).map((node) => node.id));
  const graph = {
    nodes: book.graph.nodes.filter((node) => ids.has(node.id)),
    edges: book.graph.edges.filter((edge) => ids.has(edge.source) && ids.has(edge.target)),
    tour: (book.graph.tour || [])
      .map((step) => ({ ...step, nodeIds: step.nodeIds.filter((id) => ids.has(id)) }))
      .filter((step) => step.nodeIds.length),
  };
  const seen = new Set(store.mapSeen.filter((n) => earned.includes(n)));
  const fresh = earned.filter((n) => !seen.has(n));
  const map = mountGraph($("#gm"), graph, {
    colorBy: "chapter",
    title: "Your book so far",
    chapterOrder: earned,
    grow: { seen, fresh },
  });
  if (fresh.length) {
    store.mapSeen = earned;
    persist();
  }
  if ($("#replay")) $("#replay").onclick = () => map.replay();
}
