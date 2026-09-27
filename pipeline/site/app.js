(() => {
  // src/ui/context.js
  var EMPTY_BOOK = { title: "No book yet", chapters: [], graph: { nodes: [], edges: [], layers: [], tour: [] } };
  var book = window.BOOK || EMPTY_BOOK;
  var storageKey = `nlbook:${book.title || "book"}`;
  function loadStore() {
    let saved = {};
    try {
      saved = JSON.parse(localStorage.getItem(storageKey)) || {};
    } catch {
      saved = {};
    }
    return { cards: {}, quiz: {}, loop: {}, recall: {}, remake: {}, mapPos: {}, mapSeen: [], ...saved };
  }
  var store = loadStore();
  function persist() {
    try {
      localStorage.setItem(storageKey, JSON.stringify(store));
    } catch {
    }
    if (window.parent !== window) window.parent.postMessage({ type: "nl-progress", data: store }, "*");
  }
  var now = () => Date.now();
  var renderPage = () => {
  };
  var route = { view: "home" };
  function setRenderer(render2) {
    renderPage = render2;
  }
  function go(view, params = {}) {
    route = { view, ...params };
    renderPage();
    window.scrollTo({ top: 0 });
  }
  function rerender() {
    renderPage();
  }

  // src/core/text.js
  function escapeHtml(value) {
    return String(value ?? "").replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
    );
  }
  var LEVEL = {
    deep: { pill: "p-fail", label: "Deep read" },
    skim: { pill: "p-skip", label: "Skim" },
    normal: { pill: "p-done", label: "Read" }
  };
  function levelLabel(level) {
    return LEVEL[level] || LEVEL.normal;
  }
  function withoutRepeatedTitle(text, title) {
    return text.replace(
      /^(\s*#{1,3}\s+[^\n]*\n+){1,2}/,
      (headings) => headings.toLowerCase().includes(title.toLowerCase()) ? "" : headings
    );
  }
  function markdownToHtml(text, guide = []) {
    const plan = guide.map((entry) => ({ ...entry, key: entry.section.toLowerCase().trim() }));
    return text.split(/\n{2,}/).map((block) => {
      const trimmed = block.trim();
      if (!trimmed) return "";
      const heading = trimmed.match(/^(#{1,3})\s+(.*)/);
      if (!heading) return `<p>${escapeHtml(trimmed).replace(/\n/g, " ")}</p>`;
      const title = heading[2].trim();
      const lower = title.toLowerCase();
      const match = plan.find((p) => p.key && (lower.includes(p.key) || p.key.includes(lower)));
      const tag = heading[1].length === 1 ? "h2" : "h3";
      const pill = match ? ` <span class="pill ${levelLabel(match.level).pill}">${levelLabel(match.level).label}</span>` : "";
      const note = match ? `<p class="gnote">${escapeHtml(match.why)}</p>` : "";
      return `<${tag}>${escapeHtml(title)}${pill}</${tag}>${note}`;
    }).join("");
  }

  // src/ui/dom.js
  var $ = (selector, root = document) => root.querySelector(selector);
  var $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  var esc = escapeHtml;
  var PALETTE = [
    "#E0683F",
    "#5C86E0",
    "#3FA88A",
    "#8A6FE0",
    "#E0A52A",
    "#E2577E",
    "#2FA6B8",
    "#B8743F",
    "#7C9A3A",
    "#C46BC0"
  ];
  function pip(pose, extraClass = "") {
    return `<div class="pip moving ${extraClass}">${(window.PIP || {})[pose] || ""}</div>`;
  }
  var toastTimer;
  function toast(message) {
    const el = $("#toast");
    el.textContent = message;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2200);
  }
  function confetti() {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const layer = document.createElement("div");
    layer.className = "confetti";
    for (let i = 0; i < 60; i++) {
      const piece = document.createElement("i");
      piece.style.left = `${Math.random() * 100}vw`;
      piece.style.background = PALETTE[i % PALETTE.length];
      piece.style.animationDelay = `${Math.random() * 0.6}s`;
      piece.style.transform = `rotate(${Math.random() * 360}deg)`;
      layer.appendChild(piece);
    }
    document.body.appendChild(layer);
    setTimeout(() => layer.remove(), 2600);
  }
  var STATUS = {
    done: { pill: "p-done", label: "Ready" },
    working: { pill: "p-work", label: "Pip is making this" },
    waiting_quota: { pill: "p-wait", label: "Waiting for NotebookLM's daily limit" },
    skipped: { pill: "p-skip", label: "Not made for this chapter" },
    failed: { pill: "p-fail", label: "Couldn't make this" },
    todo: { pill: "p-skip", label: "Queued" }
  };
  var statusOf = (status) => STATUS[status] || STATUS.todo;
  function notReady(chapter, kind) {
    const status = chapter.status[kind];
    const { pill, label } = statusOf(status);
    const pose = { working: "study", waiting_quota: "nap", failed: "stretch" }[status] || "read";
    let detail = "";
    if (status === "skipped" && (kind === "video" || kind === "audio")) {
      detail = chapter.notes[kind] || `Add it with <code>--media ${chapter.n}</code> next time you run the pipeline.`;
    } else if (status === "waiting_quota") {
      detail = "Run the same command again later and Pip will pick up here.";
    } else if (status === "failed") {
      detail = `${esc(chapter.notes[kind])}<br>Run again with <code>--retry</code>.`;
    } else if (status === "working") {
      detail = "This page updates by itself when it's ready.";
    }
    return `<div class="card empty">${pip(pose, "pipmid")}<span class="pill ${pill}">${label}</span>
    <p class="small muted" style="margin-top:8px">${detail}</p></div>`;
  }
  function pipAside(pose, line) {
    return `<aside class="pipside"><div class="bubble">${line}</div>${pip(pose)}</aside>`;
  }
  var ICONS = {
    video: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10l5-3v10l-5-3z"/></svg>',
    audio: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><rect x="3" y="14" width="5" height="6" rx="2"/><rect x="16" y="14" width="5" height="6" rx="2"/></svg>',
    study: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M3 5h6a3 3 0 0 1 3 3v12a2 2 0 0 0-2-2H3zM21 5h-6a3 3 0 0 0-3 3v12a2 2 0 0 1 2-2h7z"/></svg>',
    quiz: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 1-1 1.7M12 17h.01"/></svg>',
    cards: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="7" width="13" height="13" rx="3"/><path d="M8 4h10a3 3 0 0 1 3 3v10"/></svg>',
    mindmap: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="5" cy="12" r="2.5"/><circle cx="19" cy="6" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="M7.5 12h4M11.5 12c2 0 2-6 5-6M11.5 12c2 0 2 6 5 6"/></svg>',
    graph: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="6" cy="6" r="2.5"/><circle cx="18" cy="8" r="2.5"/><circle cx="9" cy="18" r="2.5"/><path d="M8.3 7l7.4.6M7 8.3l1.5 7.3M16.4 10l-5.6 6.2"/></svg>'
  };

  // src/core/loop.js
  var STAGES = [
    { id: "prime", label: "Listen & watch", verb: "Video and podcast first" },
    { id: "read", label: "Read", verb: "Read with your guide" },
    { id: "recall", label: "Recall", verb: "Recall in your own words" },
    { id: "map", label: "Map", verb: "Remake the map from memory" },
    { id: "space", label: "Remember", verb: "Review your flashcards" }
  ];
  function loopOf(store2, n) {
    var _a;
    (_a = store2.loop)[n] ?? (_a[n] = {});
    return store2.loop[n];
  }
  function isClosed(store2, n) {
    const loop = loopOf(store2, n);
    return STAGES.every((stage) => loop[stage.id]);
  }
  function nextStage(store2, n) {
    const loop = loopOf(store2, n);
    return STAGES.find((stage) => !loop[stage.id])?.id ?? null;
  }
  function isUnlocked(store2, chapters, n) {
    const index = chapters.findIndex((c) => c.n === n);
    return index <= 0 || isClosed(store2, chapters[index - 1].n);
  }
  function completeStage(store2, n, stageId, now2) {
    const loop = loopOf(store2, n);
    if (!loop[stageId]) loop[stageId] = now2;
    if (isClosed(store2, n) && !loop.closedShown) {
      loop.closedShown = true;
      return true;
    }
    return false;
  }
  function isMapped(store2, n) {
    return Boolean(loopOf(store2, n).map);
  }

  // src/core/growth.js
  var GOLDEN_ANGLE = 2.39996;
  var RING_SPACING = 150;
  function sproutPoint(k, centerX, centerY) {
    if (k <= 0) return [centerX, centerY];
    const angle = k * GOLDEN_ANGLE;
    const radius = RING_SPACING * Math.sqrt(k);
    return [centerX + radius * Math.cos(angle), centerY + radius * Math.sin(angle)];
  }

  // src/ui/graph.js
  var ARROWED = /* @__PURE__ */ new Set(["builds_on", "depends_on", "exemplifies", "categorized_under"]);
  var KINDS = [
    ["concept", "\u25CF Concepts"],
    ["claim", "\u25C6 Claims"],
    ["topic", "\u25A2 Topics"]
  ];
  var radiusOf = (node) => ({ complex: 20, moderate: 16 })[node.complexity] || 12;
  function renderChapterGraph(el, chapter) {
    const prefix = `c${chapter.n}:`;
    const nodes = book.graph.nodes.filter((node) => node.chapter === chapter.n);
    const edges = book.graph.edges.filter((edge) => edge.source.startsWith(prefix) && edge.target.startsWith(prefix));
    const tour = (chapter.graph?.tour || []).map((step) => ({ ...step, nodeIds: step.nodeIds.map((id) => prefix + id) }));
    mountGraph(el, { nodes, edges, tour }, { colorBy: "layer", title: `Chapter ${chapter.n}` });
  }
  function mountGraph(el, graph, options) {
    const chapters = options.chapterOrder || [...new Set(graph.nodes.map((node2) => node2.chapter))];
    const layers = [...new Set(graph.nodes.map((node2) => node2.layerName || node2.layer))];
    const groupOf = (node2) => options.colorBy === "chapter" ? chapters.indexOf(node2.chapter) : layers.indexOf(node2.layerName || node2.layer);
    const groupLabel = (i) => options.colorBy === "chapter" ? book.chapters.find((c) => c.n === chapters[i])?.title || `Chapter ${chapters[i]}` : layers[i];
    const view = {
      selected: null,
      detail: "learn",
      tour: -1,
      memory: false,
      revealedInMemory: /* @__PURE__ */ new Set(),
      path: null,
      query: "",
      hiddenGroups: /* @__PURE__ */ new Set(),
      kinds: new Set(KINDS.map(([k]) => k))
    };
    el.innerHTML = panelsHtml(graph, options, chapters, layers, groupLabel);
    const info = $("#ginfo");
    const wrap = $("#gc");
    if (!window.d3) {
      wrap.innerHTML = `<div style="padding:16px">${graph.nodes.map((node2) => `<p><b>${esc(node2.name)}</b><br><span class="small muted">${esc(node2.summary)}</span></p>`).join("")}</div>`;
      return { replay() {
      } };
    }
    const d3 = window.d3;
    const width = wrap.clientWidth;
    const height = wrap.clientHeight;
    const nodes = graph.nodes.map((node2) => ({ ...node2 }));
    const byId = Object.fromEntries(nodes.map((node2) => [node2.id, node2]));
    const links = graph.edges.filter((edge) => byId[edge.source] && byId[edge.target]).map((edge) => ({ ...edge }));
    const growing = Boolean(options.grow);
    const anchorOf = (node2) => growing ? sproutPoint(chapters.indexOf(node2.chapter), width / 2, height / 2) : [width / 2, height / 2];
    const visibleOnMap = new Set(
      growing ? nodes.filter((node2) => options.grow.seen.has(node2.chapter)).map((node2) => node2.id) : nodes.map((node2) => node2.id)
    );
    nodes.forEach((node2) => {
      const saved = growing && store.mapPos[node2.id];
      if (saved) {
        [node2.x, node2.y] = saved;
        [node2.fx, node2.fy] = saved;
      } else {
        const [x, y] = anchorOf(node2);
        node2.x = x + (Math.random() - 0.5) * 30;
        node2.y = y + (Math.random() - 0.5) * 30;
      }
    });
    const svg = d3.select(wrap).append("svg").attr("role", "img").attr("aria-label", "Knowledge graph");
    svg.append("defs").append("marker").attr("id", "arr").attr("viewBox", "0 0 10 10").attr("refX", 9).attr("refY", 5).attr("markerWidth", 7).attr("markerHeight", 7).attr("orient", "auto").append("path").attr("d", "M1 1L9 5L1 9").attr("fill", "none").attr("stroke", "var(--ink-3)").attr("stroke-width", 1.6);
    const layer = svg.append("g");
    const zoom = d3.zoom().scaleExtent([0.25, 3]).on("zoom", (event) => layer.attr("transform", event.transform));
    svg.call(zoom);
    const link = layer.append("g").selectAll("path").data(links).join("path").attr("class", (d) => `link ${d.type}`).attr("marker-end", (d) => ARROWED.has(d.type) ? "url(#arr)" : null);
    const node = layer.append("g").selectAll("g").data(nodes).join("g").attr("class", "node").attr("tabindex", 0).attr("role", "button").attr("aria-label", (d) => d.name);
    node.each(function drawShape(d) {
      const shape = d3.select(this);
      const r = radiusOf(d);
      const color = PALETTE[groupOf(d) % PALETTE.length];
      if (d.type === "claim")
        shape.append("path").attr("class", "shape").attr("d", `M0,${-r - 3} L${r + 3},0 L0,${r + 3} L${-r - 3},0 Z`).attr("fill", color);
      else if (d.type === "topic")
        shape.append("rect").attr("class", "shape").attr("x", -r).attr("y", -r).attr("width", 2 * r).attr("height", 2 * r).attr("rx", 7).attr("fill", color);
      else shape.append("circle").attr("class", "shape").attr("r", r).attr("fill", color);
      shape.append("circle").attr("r", Math.max(3, r * 0.32)).attr("cx", -r * 0.32).attr("cy", -r * 0.32).attr("fill", "#fff").attr("opacity", 0.45).attr("pointer-events", "none");
    });
    const label = node.append("text").attr("text-anchor", "middle").attr("dy", (d) => radiusOf(d) + 16);
    const simulation = d3.forceSimulation(nodes).force(
      "link",
      d3.forceLink(links).id((d) => d.id).distance((d) => d.type === "similar_to" ? 150 : 95).strength((d) => d.type === "similar_to" ? 0.15 : 0.6)
    ).force("charge", d3.forceManyBody().strength(-340)).force(
      "collide",
      d3.forceCollide((d) => radiusOf(d) + 26)
    ).force("x", d3.forceX((d) => anchorOf(d)[0]).strength(growing ? 0.1 : 0.05)).force("y", d3.forceY((d) => anchorOf(d)[1]).strength(growing ? 0.1 : 0.07));
    if (growing && nodes.every((n) => store.mapPos[n.id])) simulation.alpha(0.15);
    simulation.on("tick", () => {
      link.attr("d", (d) => {
        const dx = d.target.x - d.source.x;
        const dy = d.target.y - d.source.y;
        const length = Math.hypot(dx, dy) || 1;
        const stop = radiusOf(d.target) + 6;
        return `M${d.source.x},${d.source.y}L${d.target.x - dx / length * stop},${d.target.y - dy / length * stop}`;
      });
      node.attr("transform", (d) => `translate(${d.x},${d.y})`);
    });
    node.call(
      d3.drag().on("start", (event, d) => {
        if (!event.active) simulation.alphaTarget(0.25).restart();
        d.fx = d.x;
        d.fy = d.y;
      }).on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
      }).on("end", (event, d) => {
        if (!event.active) simulation.alphaTarget(0);
        if (growing) {
          store.mapPos[d.id] = [Math.round(d.x), Math.round(d.y)];
          persist();
        } else {
          d.fx = null;
          d.fy = null;
        }
      })
    );
    const neighbours = (id) => links.filter((l) => l.source.id === id || l.target.id === id).map((l) => ({ other: l.source.id === id ? l.target : l.source, link: l, outgoing: l.source.id === id }));
    const isShown = (d) => visibleOnMap.has(d.id) && !view.hiddenGroups.has(groupOf(d)) && view.kinds.has(d.type || "concept");
    const alive = () => document.body.contains(wrap);
    function highlighted() {
      if (view.path) return new Set(view.path);
      if (view.tour >= 0) return new Set(graph.tour[view.tour].nodeIds);
      if (view.selected) return /* @__PURE__ */ new Set([view.selected, ...neighbours(view.selected).map((n) => n.other.id)]);
      const q = view.query.trim().toLowerCase();
      return q ? new Set(nodes.filter((n) => `${n.name} ${n.summary}`.toLowerCase().includes(q)).map((n) => n.id)) : null;
    }
    function paint() {
      const lit = highlighted();
      const onPath = (d) => view.path && Math.abs(view.path.indexOf(d.source.id) - view.path.indexOf(d.target.id)) === 1 && view.path.includes(d.source.id) && view.path.includes(d.target.id);
      node.style("display", (d) => isShown(d) ? null : "none").classed("dim", (d) => lit ? !lit.has(d.id) : false).classed("sel", (d) => d.id === view.selected).classed("hl", (d) => view.tour >= 0 && lit.has(d.id));
      link.style("display", (d) => isShown(d.source) && isShown(d.target) ? null : "none").classed("dim", (d) => lit ? !(lit.has(d.source.id) && lit.has(d.target.id)) : false).classed("hl", onPath);
      label.text(
        (d) => view.memory && !view.revealedInMemory.has(d.id) ? "?" : d.name.length > 24 ? `${d.name.slice(0, 22)}\u2026` : d.name
      );
      $$("[data-det]", el).forEach((button) => button.setAttribute("aria-pressed", button.dataset.det === view.detail));
      $("#gblind").textContent = view.memory ? "Exit memory mode" : "Rebuild from memory";
      renderPanel();
    }
    function renderPanel() {
      if (view.tour >= 0) return tourPanel();
      if (view.memory) return memoryPanel();
      if (!view.selected) {
        info.innerHTML = `<h3>${esc(options.title)}</h3><p class="small muted">${visibleOnMap.size} ideas and ${links.length} connections. Tap any idea to see what it means and how it connects.</p>${pip("read")}`;
        return;
      }
      const d = byId[view.selected];
      const chapter = book.chapters.find((c) => c.n === d.chapter);
      const connections = view.detail === "overview" ? "" : neighbours(d.id).map(
        ({
          other,
          link: l,
          outgoing
        }) => `<button class="conn" data-go-node="${esc(other.id)}">${outgoing ? "\u2192" : "\u2190"} ${esc(other.name)}<br>
        <span class="tiny">${esc(l.type.replace(/_/g, " "))}${view.detail === "deep" && l.description ? `: ${esc(l.description)}` : ""}${other.chapter !== d.chapter ? ` \xB7 chapter ${other.chapter}` : ""}</span></button>`
      ).join("");
      info.innerHTML = `<div class="row"><span class="pill p-done">${esc(d.type || "concept")}</span><span class="pill p-skip">${esc(d.complexity)}</span></div>
      <h3 style="margin-top:8px">${esc(d.name)}</h3><p class="small">${esc(d.summary)}</p>
      ${view.detail !== "overview" && d.detail ? `<p class="small muted">${esc(d.detail)}</p>` : ""}
      <p class="tiny">From chapter ${d.chapter}: ${esc(chapter?.title || "")}${d.layerName ? ` \xB7 ${esc(d.layerName)}` : ""}</p>${connections}
      <div class="row" style="margin-top:8px"><button class="btn ghost sm" id="opench">Open chapter ${d.chapter}</button><button class="btn ghost sm" id="clr">Clear</button></div>`;
      $$("[data-go-node]", info).forEach((button) => {
        button.onclick = () => {
          view.selected = button.dataset.goNode;
          paint();
        };
      });
      $("#opench").onclick = () => go("chapter", { n: d.chapter, stage: "map", mapMode: "concepts" });
      $("#clr").onclick = () => {
        view.selected = null;
        paint();
      };
    }
    function tourPanel() {
      const step = graph.tour[view.tour];
      const last = view.tour === graph.tour.length - 1;
      info.innerHTML = `<div class="tour"><span class="pill p-work">Tour ${view.tour + 1} of ${graph.tour.length}</span><h3 style="margin:8px 0 4px">${esc(step.title)}</h3>
      <p class="small">${esc(step.description)}</p><p class="tiny">${step.nodeIds.map((id) => esc(byId[id]?.name || "")).join(" \xB7 ")}</p></div>
      <div class="row"><button class="btn ghost sm" id="tp" ${view.tour ? "" : "disabled"}>Back</button><button class="btn sm" id="tn">${last ? "Finish" : "Next"}</button><button class="btn ghost sm" id="tx">Exit</button></div>${pip(last ? "proud" : "read")}`;
      $("#tp").onclick = () => {
        view.tour -= 1;
        paint();
      };
      $("#tn").onclick = () => {
        if (last) {
          view.tour = -1;
          toast("Tour finished!");
          confetti();
        } else {
          view.tour += 1;
        }
        paint();
      };
      $("#tx").onclick = () => {
        view.tour = -1;
        paint();
      };
    }
    function memoryPanel() {
      const left = nodes.filter((n) => visibleOnMap.has(n.id) && !view.revealedInMemory.has(n.id)).length;
      if (!view.selected) {
        info.innerHTML = `<h3>Memory mode</h3><p class="small">Every label is hidden. Tap a "?" and try to name it from its neighbours. ${left} to go.</p>${pip("play")}`;
        return;
      }
      const d = byId[view.selected];
      const shown = view.revealedInMemory.has(d.id);
      const around = neighbours(d.id).map((n) => view.revealedInMemory.has(n.other.id) ? esc(n.other.name) : "?").join(", ") || "nothing";
      info.innerHTML = `<h3>${shown ? esc(d.name) : "Which idea is this?"}</h3><p class="tiny">Connected to: ${around}</p>
      ${shown ? `<p class="small">${esc(d.summary)}</p>` : '<button class="btn sm" id="rv">Reveal</button>'}<p class="tiny">${left} left</p>`;
      if (!shown) {
        $("#rv").onclick = () => {
          view.revealedInMemory.add(d.id);
          if (!nodes.some((n) => visibleOnMap.has(n.id) && !view.revealedInMemory.has(n.id))) {
            view.memory = false;
            toast("Map rebuilt from memory!");
            confetti();
          }
          paint();
        };
      }
    }
    node.on("click", (event, d) => {
      view.selected = view.selected === d.id && !view.memory ? null : d.id;
      view.path = null;
      view.tour = -1;
      paint();
    }).on("keydown", (event, d) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        view.selected = d.id;
        paint();
      }
    });
    wireControls();
    const fit = () => {
      if (!alive()) return;
      const shown = nodes.filter((n) => visibleOnMap.has(n.id));
      if (!shown.length) return;
      const xs = shown.map((n) => n.x);
      const ys = shown.map((n) => n.y);
      const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
      const scale = Math.min(1.6, 0.85 * Math.min(width / (x1 - x0 + 80), height / (y1 - y0 + 80)));
      svg.transition().duration(500).call(
        zoom.transform,
        d3.zoomIdentity.translate(width / 2 - scale * (x0 + x1) / 2, height / 2 - scale * (y0 + y1) / 2).scale(scale)
      );
    };
    let saveTimer;
    const savePositions = () => {
      if (!growing) return;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        nodes.filter((n) => visibleOnMap.has(n.id)).forEach((n) => {
          store.mapPos[n.id] = [Math.round(n.x), Math.round(n.y)];
          n.fx = n.x;
          n.fy = n.y;
        });
        persist();
      }, 300);
    };
    $("#zin").onclick = () => svg.transition().call(zoom.scaleBy, 1.3);
    $("#zout").onclick = () => svg.transition().call(zoom.scaleBy, 1 / 1.3);
    $("#zfit").onclick = fit;
    simulation.on("end", () => {
      fit();
      savePositions();
    });
    setTimeout(fit, 1500);
    paint();
    function sprout(chapterNumber) {
      if (!alive()) return;
      const fresh = nodes.filter((n) => n.chapter === chapterNumber && !visibleOnMap.has(n.id));
      if (!fresh.length) return;
      const [ax, ay] = anchorOf(fresh[0]);
      fresh.forEach((n) => {
        if (!store.mapPos[n.id]) {
          n.x = ax + (Math.random() - 0.5) * 12;
          n.y = ay + (Math.random() - 0.5) * 12;
        }
        visibleOnMap.add(n.id);
      });
      const ids = new Set(fresh.map((n) => n.id));
      node.filter((d) => ids.has(d.id)).classed("new", true).each(function stagger(d, i) {
        this.querySelectorAll(".shape, circle, text").forEach((part) => {
          part.style.animationDelay = `${i * 0.07}s`;
        });
      });
      link.filter((d) => ids.has(d.source.id) || ids.has(d.target.id)).classed("new", true);
      paint();
      simulation.alpha(0.7).restart();
      const title = book.chapters.find((c) => c.n === chapterNumber)?.title || "";
      const bridges = links.some((l) => l.type === "similar_to" && ids.has(l.source.id) !== ids.has(l.target.id));
      toast(`\u{1F331} Chapter ${chapterNumber} sprouted ${fresh.length} ideas`);
      info.innerHTML = `<h3>Your map grew!</h3><p class="small">Chapter ${chapterNumber}, \u201C${esc(title)}\u201D, added ${fresh.length} ideas${bridges ? ", and some of them connect to ideas you already knew" : ""}.</p>${pip("hop")}`;
      setTimeout(() => {
        if (!alive()) return;
        node.classed("new", false);
        link.classed("new", false);
        fit();
        savePositions();
      }, 2600);
    }
    if (growing) options.grow.fresh.forEach((n, k) => setTimeout(() => sprout(n), 900 + k * 1900));
    return {
      replay() {
        visibleOnMap.clear();
        paint();
        chapters.forEach((n, k) => setTimeout(() => sprout(n), 400 + k * 1900));
        setTimeout(
          () => {
            if (alive())
              info.innerHTML = `<h3>${esc(options.title)}</h3><p class="small muted">That's your whole map so far: ${nodes.length} ideas from ${chapters.length} chapters.</p>${pip("proud")}`;
          },
          400 + chapters.length * 1900 + 800
        );
      }
    };
    function wireControls() {
      $$("[data-det]", el).forEach((button) => {
        button.onclick = () => {
          view.detail = button.dataset.det;
          paint();
        };
      });
      $$("[data-grp]", el).forEach((box) => {
        box.onchange = () => {
          if (box.checked) view.hiddenGroups.delete(Number(box.dataset.grp));
          else view.hiddenGroups.add(Number(box.dataset.grp));
          paint();
        };
      });
      $$("[data-type]", el).forEach((box) => {
        box.onchange = () => {
          if (box.checked) view.kinds.add(box.dataset.type);
          else view.kinds.delete(box.dataset.type);
          paint();
        };
      });
      $("#gq").oninput = (event) => {
        view.query = event.target.value;
        view.selected = null;
        paint();
      };
      if ($("#gtour")) {
        $("#gtour").onclick = () => {
          Object.assign(view, { tour: 0, selected: null, path: null, memory: false });
          paint();
        };
      }
      $("#gblind").onclick = () => {
        Object.assign(view, { memory: !view.memory, selected: null, tour: -1, path: null });
        if (view.memory) view.revealedInMemory = /* @__PURE__ */ new Set();
        paint();
      };
      $("#pgo").onclick = () => {
        const path = shortestPath($("#pa").value, $("#pb").value, neighbours);
        if (!path) {
          $("#pres").textContent = "These two aren't connected yet.";
          return;
        }
        Object.assign(view, { path, selected: null, tour: -1 });
        paint();
        $("#pres").textContent = path.map((id) => byId[id].name).join(" \u2192 ");
      };
    }
  }
  function shortestPath(from, to, neighbours) {
    const previous = { [from]: null };
    const queue = [from];
    while (queue.length) {
      const current = queue.shift();
      if (current === to) break;
      for (const { other } of neighbours(current)) {
        if (!(other.id in previous)) {
          previous[other.id] = current;
          queue.push(other.id);
        }
      }
    }
    if (!(to in previous)) return null;
    const path = [];
    for (let at = to; at !== null; at = previous[at]) path.unshift(at);
    return path;
  }
  function panelsHtml(graph, options, chapters, layers, groupLabel) {
    const groups = options.colorBy === "chapter" ? chapters : layers;
    const nodeOptions = graph.nodes.map((node) => `<option value="${esc(node.id)}">${esc(node.name)}</option>`).join("");
    return `<div class="gshell">
    <div class="gpanel"><h3>Explore</h3><input type="search" id="gq" placeholder="Search ideas\u2026" aria-label="Search ideas">
      <div class="seg" role="group" aria-label="Detail">${[
      ["overview", "Overview"],
      ["learn", "Learn"],
      ["deep", "Deep dive"]
    ].map(([id, text]) => `<button data-det="${id}" aria-pressed="${id === "learn"}">${text}</button>`).join("")}</div>
      <div><h3 style="margin-bottom:6px">${options.colorBy === "chapter" ? "Chapters" : "Groups"}</h3>
        ${groups.map((_, i) => `<label class="chk"><input type="checkbox" data-grp="${i}" checked><i style="background:${PALETTE[i % PALETTE.length]}"></i>${esc(groupLabel(i))}</label>`).join("")}</div>
      <div><h3 style="margin-bottom:6px">Kinds</h3>${KINDS.map(([id, text]) => `<label class="chk"><input type="checkbox" data-type="${id}" checked>${text}</label>`).join("")}</div>
      <div class="row">${graph.tour?.length ? '<button class="btn sm" id="gtour">Guided tour</button>' : ""}<button class="btn ghost sm" id="gblind">Rebuild from memory</button></div>
      <details><summary class="small"><b>How are two ideas connected?</b></summary>
        <select id="pa" style="margin-top:8px">${nodeOptions}</select><select id="pb" style="margin-top:6px">${nodeOptions}</select>
        <button class="btn sm" id="pgo" style="margin-top:8px">Show path</button><p class="tiny" id="pres"></p></details>
    </div>
    <div class="gcanvas" id="gc"><div class="zoom"><button id="zin" aria-label="Zoom in">+</button><button id="zout" aria-label="Zoom out">\u2212</button><button id="zfit" aria-label="Fit">\u2922</button></div></div>
    <div class="gpanel info" id="ginfo" aria-live="polite"></div></div>`;
  }

  // src/ui/bookmap.js
  function viewBookMap(el) {
    const ideaCount = (n) => book.graph.nodes.filter((node) => node.chapter === n).length;
    const earned = book.chapters.filter((c) => isMapped(store, c.n) && ideaCount(c.n)).map((c) => c.n);
    el.innerHTML = `<h2>Book map</h2>
    <p class="muted" style="margin:6px 0 12px">Your map of the book grows with every chapter you map. Dashed lines join the same idea across chapters; pink dotted lines show disagreements.</p>
    <div class="growstrip" id="strip"></div><div id="gm"></div>`;
    const chips = book.chapters.map((c) => {
      if (earned.includes(c.n)) {
        return `<span class="gchip"><i style="background:${PALETTE[earned.indexOf(c.n) % PALETTE.length]}"></i>\u{1F331} Chapter ${c.n} \xB7 ${ideaCount(c.n)} ideas</span>`;
      }
      return `<span class="gchip future">${isUnlocked(store, book.chapters, c.n) ? "\u{1F330}" : "\u{1F512}"} Chapter ${c.n}</span>`;
    });
    $("#strip").innerHTML = chips.join("") + (earned.length > 1 ? '<button class="btn ghost sm" id="replay">\u25B6 Replay growth</button>' : "");
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
      tour: (book.graph.tour || []).map((step) => ({ ...step, nodeIds: step.nodeIds.filter((id) => ids.has(id)) })).filter((step) => step.nodeIds.length)
    };
    const seen = new Set(store.mapSeen.filter((n) => earned.includes(n)));
    const fresh = earned.filter((n) => !seen.has(n));
    const map2 = mountGraph($("#gm"), graph, {
      colorBy: "chapter",
      title: "Your book so far",
      chapterOrder: earned,
      grow: { seen, fresh }
    });
    if (fresh.length) {
      store.mapSeen = earned;
      persist();
    }
    if ($("#replay")) $("#replay").onclick = () => map2.replay();
  }

  // src/core/recall.js
  var STOP_WORDS = /* @__PURE__ */ new Set(["with", "that", "this", "from", "into", "your", "about", "when", "what", "they", "their"]);
  function recallScore(covered, total) {
    return total ? Math.round(3 * covered / total) : 0;
  }
  function significantWords(text) {
    return String(text).toLowerCase().replace(/[^a-z0-9 ]+/g, " ").split(/\s+/).filter((w) => w.length > 3 && !STOP_WORDS.has(w));
  }
  function namesMatch(guess, truth) {
    const g = guess.toLowerCase().trim();
    const t = truth.toLowerCase().trim();
    if (!g || !t) return false;
    if (g.includes(t) || t.includes(g)) return true;
    const guessWords = significantWords(guess);
    const truthWords = significantWords(truth);
    if (!guessWords.length || !truthWords.length) return false;
    const sameStem = (a, b) => a === b || a.length > 4 && b.length > 4 && a.slice(0, 5) === b.slice(0, 5);
    const hits = truthWords.filter((tw) => guessWords.some((gw) => sameStem(gw, tw))).length;
    return hits / truthWords.length >= 0.5;
  }
  function compareRemake(typed, mindMap) {
    const lines = typed.split("\n").map((l) => l.trim()).filter(Boolean);
    const branches = lines.filter((l) => !l.startsWith("-"));
    const subIdeas = lines.filter((l) => l.startsWith("-")).map((l) => l.replace(/^-+\s*/, ""));
    const everything = [...branches, ...subIdeas];
    let found = 0;
    let total = 0;
    const rows = (mindMap.children || []).map((branch) => {
      const remembered = everything.some((line) => namesMatch(line, branch.name));
      const children = (branch.children || []).map((child) => {
        const hit = everything.some((line) => namesMatch(line, child.name));
        found += hit;
        total += 1;
        return { name: child.name, remembered: hit };
      });
      found += remembered;
      total += 1;
      return { name: branch.name, remembered, children };
    });
    return { rows, lines, percent: total ? Math.round(100 * found / total) : 0 };
  }

  // src/core/cards.js
  function unlockedCards(chapters, store2) {
    return chapters.filter((chapter) => isUnlocked(store2, chapters, chapter.n)).flatMap(
      (chapter) => (chapter.cards || []).map((card, i) => ({ ...card, id: `${chapter.n}:${i}`, chapter: chapter.n }))
    );
  }
  function dueCards(chapters, store2, now2) {
    return unlockedCards(chapters, store2).filter((card) => {
      const state = store2.cards[card.id];
      return !state || state.due <= now2;
    });
  }

  // src/core/fsrs.js
  var WEIGHTS = [
    0.4872,
    1.4003,
    3.7145,
    13.8206,
    5.1618,
    1.2298,
    0.8975,
    0.031,
    1.6474,
    0.1367,
    1.0461,
    2.1072,
    0.0793,
    0.3246,
    1.587,
    0.2272,
    2.8755
  ];
  var DECAY = -0.5;
  var FACTOR = 19 / 81;
  var DAY_MS = 864e5;
  var RELEARN_MS = 10 * 6e4;
  var MAX_INTERVAL_DAYS = 365;
  var clampDifficulty = (d) => Math.min(10, Math.max(1, d));
  function retrievability(elapsedDays, stability) {
    return Math.pow(1 + FACTOR * elapsedDays / stability, DECAY);
  }
  function grade(card, rating, now2) {
    const w = WEIGHTS;
    const next = { ...card };
    if (!card.reps) {
      next.s = w[rating - 1];
      next.d = clampDifficulty(w[4] - (rating - 3) * w[5]);
    } else {
      const r = retrievability((now2 - card.last) / DAY_MS, card.s);
      const d = card.d;
      next.d = clampDifficulty(w[7] * (w[4] - w[5]) + (1 - w[7]) * (d - w[6] * (rating - 3)));
      if (rating === 1) {
        next.s = w[11] * Math.pow(d, -w[12]) * (Math.pow(card.s + 1, w[13]) - 1) * Math.exp(w[14] * (1 - r));
      } else {
        const hardPenalty = rating === 2 ? w[15] : 1;
        const easyBonus = rating === 4 ? w[16] : 1;
        next.s = card.s * (1 + Math.exp(w[8]) * (11 - d) * Math.pow(card.s, -w[9]) * (Math.exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus);
      }
    }
    next.s = Math.max(0.1, next.s);
    next.reps = (card.reps || 0) + 1;
    next.last = now2;
    next.due = rating === 1 ? now2 + RELEARN_MS : now2 + Math.min(MAX_INTERVAL_DAYS, Math.max(1, Math.round(next.s))) * DAY_MS;
    return next;
  }
  function formatWait(due, now2) {
    const ms = due - now2;
    if (ms < 36e5) return `${Math.max(1, Math.round(ms / 6e4))} min`;
    if (ms < DAY_MS) return `${Math.round(ms / 36e5)} h`;
    return `${Math.round(ms / DAY_MS)} d`;
  }

  // src/ui/flashcards.js
  var GRADES = [
    [1, "Again"],
    [2, "Hard"],
    [3, "Good"],
    [4, "Easy"]
  ];
  function reviewSession(el, cards, title, done) {
    const queue = [...cards];
    let index = 0;
    let flipped = false;
    let remembered = 0;
    const draw = () => {
      if (index >= queue.length) return finished();
      const card = queue[index];
      const state = store.cards[card.id] || {};
      const grades = GRADES.map(
        ([g, label]) => `<button class="g${g}" data-g="${g}">${label}<small>${formatWait(grade(state, g, now()).due, now())}</small></button>`
      ).join("");
      el.innerHTML = `<p class="small muted" style="text-align:center">${esc(title)} \xB7 card ${index + 1} of ${queue.length}</p>
      <div class="fc ${flipped ? "flip" : ""}" id="fc" tabindex="0" role="button" aria-label="${flipped ? "Answer shown" : "Show answer"}">
        <div class="fc-in"><div class="face"><small>Question</small>${esc(card.front)}</div><div class="face back"><small>Answer</small>${esc(card.back)}</div></div></div>
      ${flipped ? `<div class="grades">${grades}</div>` : '<div class="row" style="justify-content:center;margin-top:14px"><button class="btn" id="show">Show answer</button></div>'}
      <p class="tiny" style="text-align:center;margin-top:10px">Space flips \xB7 1\u20134 grades</p>`;
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
  function viewReview(el) {
    el.innerHTML = '<h2 style="margin-bottom:14px">Review</h2><div id="rv"></div>';
    reviewSession($("#rv"), dueCards(book.chapters, store, now()), "Whole book", ["Back to chapters", () => go("home")]);
  }

  // src/ui/mindmap.js
  function renderMindMap(el, mindMap) {
    el.innerHTML = `<div class="gcanvas mm" id="mm"><div class="gtools"><span class="pill p-done">Tap a branch to fold or unfold it</span></div>
    <div class="zoom"><button id="mmfit" aria-label="Fit">\u2922</button></div></div>`;
    const wrap = $("#mm");
    if (!window.d3) {
      wrap.innerHTML = `<pre style="padding:16px">${esc(JSON.stringify(mindMap, null, 2))}</pre>`;
      return;
    }
    const d3 = window.d3;
    const root = d3.hierarchy(mindMap, (d) => d.children);
    root.x0 = 0;
    root.y0 = 0;
    root.descendants().forEach((node, i) => {
      node.id = i;
      const branch = node.depth === 0 ? null : node.ancestors().at(-2);
      node.color = branch ? PALETTE[branch.parent.children.indexOf(branch) % PALETTE.length] : "var(--accent)";
      if (node.depth > 1) {
        node.hidden = node.children;
        node.children = null;
      }
    });
    const svg = d3.select(wrap).append("svg");
    const layer = svg.append("g");
    const zoom = d3.zoom().scaleExtent([0.3, 2.5]).on("zoom", (event) => layer.attr("transform", event.transform));
    svg.call(zoom);
    const tree = d3.tree().nodeSize([46, 230]);
    const curve = (link) => {
      const midY = (link.source.y + link.target.y) / 2;
      return `M${link.source.y},${link.source.x}C${midY},${link.source.x} ${midY},${link.target.x} ${link.target.y},${link.target.x}`;
    };
    const update = (from) => {
      tree(root);
      const nodes = root.descendants();
      const links = layer.selectAll("path.mmlink").data(root.links(), (link) => link.target.id);
      links.enter().append("path").attr("class", "mmlink").attr("stroke", (link) => link.target.color).merge(links).transition().duration(300).attr("d", curve);
      links.exit().remove();
      const groups = layer.selectAll("g.mmnode").data(nodes, (node) => node.id);
      const entering = groups.enter().append("g").attr("class", "mmnode").attr("transform", `translate(${from.y0},${from.x0})`).on("click", (event, node) => {
        [node.children, node.hidden] = node.children ? [null, node.children] : [node.hidden, null];
        update(node);
      });
      entering.append("rect");
      entering.append("text").attr("dy", "0.35em").attr("x", 12);
      const all = entering.merge(groups);
      all.select("text").text((node) => node.data.name + (node.hidden ? "  +" : ""));
      all.each(function sizeBox(node) {
        const width = Math.min(260, this.querySelector("text").getComputedTextLength() + 24);
        d3.select(this).select("rect").attr("x", 0).attr("y", -15).attr("width", width).attr("height", 30).attr("fill", node.depth === 0 ? "var(--accent-soft)" : "var(--surface)").attr("stroke", node.color);
      });
      all.transition().duration(300).attr("transform", (node) => `translate(${node.y},${node.x})`);
      groups.exit().remove();
      nodes.forEach((node) => {
        node.x0 = node.x;
        node.y0 = node.y;
      });
    };
    update(root);
    const fit = () => svg.transition().duration(400).call(zoom.transform, d3.zoomIdentity.translate(60, wrap.clientHeight / 2));
    fit();
    $("#mmfit").onclick = fit;
  }

  // src/ui/quiz.js
  var LETTERS = "ABCDEF";
  function renderQuiz(el, chapter, onDone) {
    var _a, _b;
    const questions = chapter.quiz || [];
    (_a = store.quiz)[_b = chapter.n] ?? (_a[_b] = { i: 0, results: [] });
    const progress = store.quiz[chapter.n];
    if (progress.i >= questions.length) return scoreScreen(el, chapter, onDone);
    const q = questions[progress.i];
    const bar = questions.map(
      (_, i) => `<i class="${i < progress.i ? progress.results[i] ? "right" : "wrong" : i === progress.i ? "now" : ""}"></i>`
    ).join("");
    el.innerHTML = `<div class="pane with-pip"><div class="qwrap">
    <div class="qprog">${bar}</div>
    <div class="qcard"><p class="tiny" style="margin:0 0 6px">Question ${progress.i + 1} of ${questions.length}</p><h3>${esc(q.q)}</h3>
      ${q.options.map((option, i) => `<button class="opt" data-o="${i}"><span class="let">${LETTERS[i]}</span><span>${esc(option)}<span class="why" hidden></span></span></button>`).join("")}
      <div class="row" style="margin-top:14px">${q.hint ? '<button class="btn ghost sm" id="hintb">Show a hint</button>' : ""}</div>
      <div id="hintbox"></div><div id="next" style="margin-top:14px"></div></div>
  </div>${pipAside("read", "Take your time. Guessing and checking is how memory grows.")}</div>`;
    if (q.hint) {
      $("#hintb").onclick = () => {
        $("#hintbox").innerHTML = `<div class="hint">\u{1F4A1} ${esc(q.hint)}</div>`;
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

  // src/ui/stages.js
  function listenAndWatch(el, chapter, showFinish) {
    const hasVideo = chapter.status.video === "done";
    const hasAudio = chapter.status.audio === "done";
    const placeholder = (kind) => {
      const status = chapter.status[kind];
      const hint = {
        skipped: chapter.notes[kind] || `Add it with --media ${chapter.n}`,
        waiting_quota: "Waiting for NotebookLM's daily limit",
        working: "Pip is making it now"
      }[status] || "";
      return `<div class="card empty" style="padding:18px"><span class="pill ${statusOf(status).pill}">${statusOf(status).label}</span><p class="tiny" style="margin-top:6px">${esc(hint)}</p></div>`;
    };
    el.innerHTML = `<p class="small muted" style="margin:0 0 12px">Watch the video, then play the podcast on a walk. Hearing the ideas first makes the chapter feel familiar when you read it.</p>
    <div class="lw">
      <section><h3 style="margin-bottom:8px">\u{1F3AC} Watch</h3>${hasVideo ? `<div class="card" style="padding:10px"><video class="media" controls preload="metadata" src="${esc(chapter.video)}"></video></div>` : placeholder("video")}</section>
      <section><h3 style="margin-bottom:8px">\u{1F3A7} Listen</h3>${hasAudio ? `<div class="card"><p class="small muted" style="margin:0 0 8px">Two hosts talk it through.</p><audio controls preload="metadata" style="width:100%" src="${esc(chapter.audio)}"></audio></div>` : placeholder("audio")}
        <div style="max-width:220px;margin:14px auto 0">${pip(hasVideo ? "read" : "nap")}</div></section>
    </div>`;
    showFinish("Done watching and listening \xB7 start reading");
  }
  function read(el, chapter, showFinish) {
    const guide = chapter.status.study === "done" ? chapter.guide || [] : [];
    const plan = guide.length ? `<div class="card" style="margin-bottom:14px"><h3 style="margin-bottom:8px">Your reading plan</h3><div class="plan">${guide.map(
      (entry) => `<div><span class="pill ${levelLabel(entry.level).pill}" style="flex:none">${levelLabel(entry.level).label}</span><span class="small"><b>${esc(entry.section)}</b>: ${esc(entry.why)}</span></div>`
    ).join("")}</div></div>` : `<p class="small muted">${chapter.status.study === "working" ? "Pip is writing your reading plan\u2026" : "No reading plan for this chapter yet."}</p>`;
    const source = chapter.read;
    let body;
    if (!source)
      body = `<div class="card empty"><p class="muted">The chapter file wasn't found next to this page.</p></div>`;
    else if (source.kind === "pdf")
      body = `<iframe class="pdf" src="${esc(source.file)}" title="Chapter ${chapter.n}"></iframe><p class="tiny">If the chapter doesn't show here, <a href="${esc(source.file)}" target="_blank">open it in a new tab</a>.</p>`;
    else
      body = `<article class="card reader">${markdownToHtml(withoutRepeatedTitle(source.text, chapter.title), guide)}</article>`;
    el.innerHTML = plan + body;
    showFinish("I've finished reading \xB7 recall it");
  }
  function recall(el, chapter, showFinish) {
    var _a, _b;
    const prompts = chapter.status.study === "done" ? chapter.recall || [] : [];
    (_a = store.recall)[_b = chapter.n] ?? (_a[_b] = { i: 0, scores: [] });
    const progress = store.recall[chapter.n];
    const quizReady = chapter.status.quiz === "done";
    const toMap = () => {
      finishStage(chapter.n, "recall");
      route.stage = "map";
      rerender();
    };
    if (progress.i < prompts.length) return recallPrompt(el, chapter, showFinish, prompts, progress, quizReady);
    if (quizReady) return renderQuiz(el, chapter, ["Continue to the map", toMap]);
    el.innerHTML = prompts.length ? `<div class="card empty">${pip("proud", "pipmid")}<h3>Recall done</h3></div>` : notReady(chapter, "study");
    showFinish("Continue to the map");
  }
  function recallPrompt(el, chapter, showFinish, prompts, progress, quizReady) {
    const prompt = prompts[progress.i];
    el.innerHTML = `<div class="pane with-pip"><div class="qwrap"><div class="qcard">
      <p class="tiny" style="margin:0 0 6px">In your own words \xB7 ${progress.i + 1} of ${prompts.length}</p><h3>${esc(prompt.prompt)}</h3>
      <textarea id="ans" placeholder="Explain it like you're telling a teammate. A rough attempt counts."></textarea>
      <div class="row" style="margin-top:10px"><button class="btn" id="chk">Check myself</button><button class="btn ghost sm" id="skip">Skip</button></div>
      <div id="kps"></div></div></div>${pipAside("read", "Struggling a little is what makes it stick. Write before you peek.")}</div>`;
    const answer2 = $("#ans");
    const next = () => {
      progress.i += 1;
      progress.draft = "";
      persist();
      recall(el, chapter, showFinish);
    };
    answer2.value = progress.draft || "";
    answer2.oninput = () => {
      progress.draft = answer2.value;
      persist();
    };
    $("#skip").onclick = () => {
      progress.scores[progress.i] = null;
      next();
    };
    $("#chk").onclick = () => {
      if (answer2.value.trim().length < 15) return toast("Write a sentence or two first");
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
        $("#kps").innerHTML = `<div class="row" style="margin-top:14px"><b>Score</b><span class="score">${[1, 2, 3].map((n) => `<i class="${n <= score ? "on" : ""}"></i>`).join("")}</span><span class="small muted">${score}/3</span></div>
        <p class="small muted">${score === 3 ? "You explained it fully. That's real understanding." : "The points you missed are worth a second look in the reading."}</p>
        <button class="btn" id="nx">${lastPrompt ? quizReady ? "On to the quiz" : "Continue" : "Next question"}</button>`;
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
    const mode = route.mapMode || (hasMindMap ? isMapped(store, chapter.n) ? "mind" : "remake" : "concepts");
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
    showFinish(isMapped(store, chapter.n) ? "Continue to flashcards" : "I've got the big picture \xB7 flashcards");
  }
  function remake(el, chapter, onSeeFullMap) {
    var _a, _b;
    const mindMap = chapter.mindmap || { name: chapter.title, children: [] };
    (_a = store.remake)[_b = chapter.n] ?? (_a[_b] = {});
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
      const rows = result.rows.map(
        (row) => `<div class="branch ${row.remembered ? "hit" : "miss"}">${row.remembered ? "\u2713 " : ""}${esc(row.name)}${row.children.map((child) => `<small>${child.remembered ? "\u2713" : "\xB7"} ${esc(child.name)}</small>`).join("")}</div>`
      ).join("");
      const good = result.percent >= 70;
      $("#cres").innerHTML = `<div class="remake" style="margin-top:14px">
      <div><p class="small"><b>The real map</b> (green = you remembered it)</p>${rows}</div>
      <div><p class="small"><b>Your version</b></p>${result.lines.map((line) => `<div class="branch" style="background:var(--sunk)">${esc(line)}</div>`).join("")}
        <p style="margin-top:12px"><b style="font-family:var(--display);font-size:1.6rem">${result.percent}%</b> <span class="small muted">remembered${saved.best > result.percent ? ` \xB7 best ${saved.best}%` : ""}</span></p>
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
      }
    ]);
  }
  var STAGE_VIEWS = { prime: listenAndWatch, read, recall, map, space: remember };

  // src/ui/chapter.js
  function viewChapter(el) {
    var _a;
    const chapter = book.chapters.find((c) => c.n === route.n);
    if (!chapter) return go("home");
    if (!isUnlocked(store, book.chapters, chapter.n)) return lockedChapter(el, chapter);
    const loop = loopOf(store, chapter.n);
    (_a = route).stage || (_a.stage = nextStage(store, chapter.n) || "prime");
    store.last = { n: chapter.n, stage: route.stage };
    persist();
    el.innerHTML = `<button class="back" id="back">\u2039 All chapters</button>
    <div class="chapter-head"><span class="bignum">${chapter.n}</span><h2>${esc(chapter.title)}</h2></div>
    <nav class="stepper" aria-label="Loop steps">${STAGES.map(
      (stage, i) => `
      <button data-stage="${stage.id}" class="${loop[stage.id] ? "done" : ""}" ${stage.id === route.stage ? 'aria-current="step"' : ""}>
        <span class="n">${loop[stage.id] ? "\u2713" : i + 1}</span>${stage.label}<small>${stage.verb}</small></button>`
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
  function finishStage(n, stageId) {
    const alreadyDone = Boolean(loopOf(store, n)[stageId]);
    const closedNow = completeStage(store, n, stageId, now());
    persist();
    if (!alreadyDone) {
      const ideas = book.graph.nodes.filter((node) => node.chapter === n).length;
      toast(
        stageId === "map" && ideas ? `\u{1F331} ${ideas} new ideas joined your book map` : `${STAGES.find((s) => s.id === stageId).label} done`
      );
    }
    if (closedNow) celebrate(n);
  }
  function lockedChapter(el, chapter) {
    const previous = book.chapters[book.chapters.findIndex((c) => c.n === chapter.n) - 1];
    el.innerHTML = `<button class="back" id="back">\u2039 All chapters</button>
    <div class="card empty" style="margin-top:14px">${pip("nap", "pipmid")}<h3>Chapter ${chapter.n} is still locked</h3>
      <p class="muted">Close the loop for chapter ${previous.n}, \u201C${esc(previous.title)}\u201D, and this one unlocks. One chapter at a time is how it sticks.</p>
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
    ${next ? `<p><b>\u{1F513} Chapter ${next.n}, \u201C${esc(next.title)}\u201D, is unlocked!</b></p>` : "<p><b>\u{1F389} That was the last chapter. You finished the whole book!</b></p>"}
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

  // src/ui/home.js
  var MATERIALS = [
    ["video", "Video"],
    ["audio", "Podcast"],
    ["study", "Reading guide and recall prompts"],
    ["quiz", "Quiz"],
    ["cards", "Flashcards"],
    ["mindmap", "Mind map"],
    ["graph", "Concept graph"]
  ];
  function viewHome(el) {
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
      <p class="muted">${esc(book.source || "")}${book.dryRun ? " \xB7 dry run" : ""}</p>
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
    <div class="grid">${chapters.map((chapter, i) => chapterCard(chapter, chapters[i - 1])).join("")}</div>`;
    $$("[data-ch]", el).forEach((card) => {
      card.onclick = () => card.dataset.locked ? toast(`Close chapter ${card.dataset.locked}'s loop first. Pip is saving this one for you.`) : go("chapter", { n: Number(card.dataset.ch) });
    });
    if (last && lastNext) $("#resume").onclick = () => go("chapter", { n: last.n, stage: lastNext });
    if (due) $("#goreview").onclick = () => go("review");
    $("#gomap").onclick = () => go("map");
  }
  var stat = (value, label) => `<div class="stat"><b>${value}</b><span class="tiny">${label}</span></div>`;
  function resumeCard(chapter, stageId) {
    const stage = STAGES.find((s) => s.id === stageId);
    return `<button class="resume" id="resume"><div>
    <span>Pick up where you left off \xB7 Chapter ${chapter.n}</span><b>${esc(chapter.title)}</b><span>Next: ${stage.verb}</span>
  </div></button>`;
  }
  function chapterCard(chapter, previous) {
    const loop = loopOf(store, chapter.n);
    const open = isUnlocked(store, book.chapters, chapter.n);
    const dots = STAGES.map((s) => `<b class="${loop[s.id] ? "on" : ""}" title="${s.label}"></b>`).join("");
    const icons = MATERIALS.map(
      ([kind, label]) => `<span class="ico ${chapter.status[kind]}" title="${label}: ${statusOf(chapter.status[kind]).label}">${ICONS[kind]}</span>`
    ).join("");
    return `<button class="ch ${open ? "" : "locked"}" data-ch="${chapter.n}" ${open ? "" : `aria-disabled="true" data-locked="${previous.n}"`}>
    <div class="row" style="justify-content:space-between"><span class="num">${chapter.n}</span>
      <span class="loopdots" aria-label="${STAGES.filter((s) => loop[s.id]).length} of 5 loop steps done">${dots}</span></div>
    <h3>${esc(chapter.title)}</h3>
    ${open ? "" : `<span class="lockline">\u{1F512} Finish chapter ${previous.n}'s loop to unlock</span>`}
    <div class="icons">${icons}</div></button>`;
  }

  // src/main.js
  var VIEWS = { home: viewHome, chapter: viewChapter, map: viewBookMap, review: viewReview };
  var REFRESH_MS = 1e4;
  function render() {
    $("#booktitle").textContent = book.title;
    document.title = `${book.title} \xB7 NeuralLoop`;
    $$("[data-go]").forEach((button) => {
      const current = route.view === button.dataset.go || route.view === "chapter" && button.dataset.go === "home";
      button.setAttribute("aria-current", current ? "page" : "false");
    });
    (VIEWS[route.view] || viewHome)($("#main"));
  }
  function refreshWhileWorking() {
    const statusSignature = (data) => JSON.stringify(data.chapters.map((c) => c.status));
    const stillWorking = () => book.chapters.some((c) => Object.values(c.status).some((s) => s === "working" || s === "todo"));
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
})();
