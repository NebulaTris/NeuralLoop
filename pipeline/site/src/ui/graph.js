// Interactive knowledge graph in the style of Understand-Anything's explorer.
// Used for one chapter's concepts and, with `grow`, for the whole book map as it grows.

import { sproutPoint } from "../core/growth.js";
import { book, go, persist, store } from "./context.js";
import { $, $$, PALETTE, confetti, esc, pip, toast } from "./dom.js";

const ARROWED = new Set(["builds_on", "depends_on", "exemplifies", "categorized_under"]);
const KINDS = [
  ["concept", "● Concepts"],
  ["claim", "◆ Claims"],
  ["topic", "▢ Topics"],
];
const radiusOf = (node) => ({ complex: 20, moderate: 16 })[node.complexity] || 12;

export function renderChapterGraph(el, chapter) {
  const prefix = `c${chapter.n}:`;
  const nodes = book.graph.nodes.filter((node) => node.chapter === chapter.n);
  const edges = book.graph.edges.filter((edge) => edge.source.startsWith(prefix) && edge.target.startsWith(prefix));
  const tour = (chapter.graph?.tour || []).map((step) => ({ ...step, nodeIds: step.nodeIds.map((id) => prefix + id) }));
  mountGraph(el, { nodes, edges, tour }, { colorBy: "layer", title: `Chapter ${chapter.n}` });
}

/**
 * options: { colorBy: "chapter" | "layer", title, chapterOrder?, grow?: { seen: Set, fresh: number[] } }
 * With `grow`, ideas keep their saved positions and new chapters sprout in; returns { replay }.
 */
export function mountGraph(el, graph, options) {
  const chapters = options.chapterOrder || [...new Set(graph.nodes.map((node) => node.chapter))];
  const layers = [...new Set(graph.nodes.map((node) => node.layerName || node.layer))];
  const groupOf = (node) =>
    options.colorBy === "chapter" ? chapters.indexOf(node.chapter) : layers.indexOf(node.layerName || node.layer);
  const groupLabel = (i) =>
    options.colorBy === "chapter"
      ? book.chapters.find((c) => c.n === chapters[i])?.title || `Chapter ${chapters[i]}`
      : layers[i];
  const view = {
    selected: null,
    detail: "learn",
    tour: -1,
    memory: false,
    revealedInMemory: new Set(),
    path: null,
    query: "",
    hiddenGroups: new Set(),
    kinds: new Set(KINDS.map(([k]) => k)),
  };

  el.innerHTML = panelsHtml(graph, options, chapters, layers, groupLabel);
  const info = $("#ginfo");
  const wrap = $("#gc");
  if (!window.d3) {
    wrap.innerHTML = `<div style="padding:16px">${graph.nodes.map((node) => `<p><b>${esc(node.name)}</b><br><span class="small muted">${esc(node.summary)}</span></p>`).join("")}</div>`;
    return { replay() {} };
  }
  const d3 = window.d3;
  const width = wrap.clientWidth;
  const height = wrap.clientHeight;
  const nodes = graph.nodes.map((node) => ({ ...node }));
  const byId = Object.fromEntries(nodes.map((node) => [node.id, node]));
  const links = graph.edges.filter((edge) => byId[edge.source] && byId[edge.target]).map((edge) => ({ ...edge }));
  const growing = Boolean(options.grow);
  const anchorOf = (node) =>
    growing ? sproutPoint(chapters.indexOf(node.chapter), width / 2, height / 2) : [width / 2, height / 2];
  const visibleOnMap = new Set(
    growing
      ? nodes.filter((node) => options.grow.seen.has(node.chapter)).map((node) => node.id)
      : nodes.map((node) => node.id),
  );

  nodes.forEach((node) => {
    const saved = growing && store.mapPos[node.id];
    if (saved) {
      [node.x, node.y] = saved;
      [node.fx, node.fy] = saved; // existing ideas never move as the map grows
    } else {
      const [x, y] = anchorOf(node);
      node.x = x + (Math.random() - 0.5) * 30;
      node.y = y + (Math.random() - 0.5) * 30;
    }
  });

  const svg = d3.select(wrap).append("svg").attr("role", "img").attr("aria-label", "Knowledge graph");
  svg
    .append("defs")
    .append("marker")
    .attr("id", "arr")
    .attr("viewBox", "0 0 10 10")
    .attr("refX", 9)
    .attr("refY", 5)
    .attr("markerWidth", 7)
    .attr("markerHeight", 7)
    .attr("orient", "auto")
    .append("path")
    .attr("d", "M1 1L9 5L1 9")
    .attr("fill", "none")
    .attr("stroke", "var(--ink-3)")
    .attr("stroke-width", 1.6);
  const layer = svg.append("g");
  const zoom = d3
    .zoom()
    .scaleExtent([0.25, 3])
    .on("zoom", (event) => layer.attr("transform", event.transform));
  svg.call(zoom);
  const link = layer
    .append("g")
    .selectAll("path")
    .data(links)
    .join("path")
    .attr("class", (d) => `link ${d.type}`)
    .attr("marker-end", (d) => (ARROWED.has(d.type) ? "url(#arr)" : null));
  const node = layer
    .append("g")
    .selectAll("g")
    .data(nodes)
    .join("g")
    .attr("class", "node")
    .attr("tabindex", 0)
    .attr("role", "button")
    .attr("aria-label", (d) => d.name);
  node.each(function drawShape(d) {
    const shape = d3.select(this);
    const r = radiusOf(d);
    const color = PALETTE[groupOf(d) % PALETTE.length];
    if (d.type === "claim")
      shape
        .append("path")
        .attr("class", "shape")
        .attr("d", `M0,${-r - 3} L${r + 3},0 L0,${r + 3} L${-r - 3},0 Z`)
        .attr("fill", color);
    else if (d.type === "topic")
      shape
        .append("rect")
        .attr("class", "shape")
        .attr("x", -r)
        .attr("y", -r)
        .attr("width", 2 * r)
        .attr("height", 2 * r)
        .attr("rx", 7)
        .attr("fill", color);
    else shape.append("circle").attr("class", "shape").attr("r", r).attr("fill", color);
    shape
      .append("circle")
      .attr("r", Math.max(3, r * 0.32))
      .attr("cx", -r * 0.32)
      .attr("cy", -r * 0.32)
      .attr("fill", "#fff")
      .attr("opacity", 0.45)
      .attr("pointer-events", "none");
  });
  const label = node
    .append("text")
    .attr("text-anchor", "middle")
    .attr("dy", (d) => radiusOf(d) + 16);

  const simulation = d3
    .forceSimulation(nodes)
    .force(
      "link",
      d3
        .forceLink(links)
        .id((d) => d.id)
        .distance((d) => (d.type === "similar_to" ? 150 : 95))
        .strength((d) => (d.type === "similar_to" ? 0.15 : 0.6)),
    )
    .force("charge", d3.forceManyBody().strength(-340))
    .force(
      "collide",
      // Room for the label too, so names never sit on top of each other.
      d3.forceCollide((d) => Math.max(radiusOf(d) + 26, (d.name || "").length * 4.2 + 12)),
    )
    .force("x", d3.forceX((d) => anchorOf(d)[0]).strength(growing ? 0.1 : 0.05))
    .force("y", d3.forceY((d) => anchorOf(d)[1]).strength(growing ? 0.1 : 0.07));
  if (growing && nodes.every((n) => store.mapPos[n.id])) simulation.alpha(0.15);
  simulation.on("tick", () => {
    link.attr("d", (d) => {
      const dx = d.target.x - d.source.x;
      const dy = d.target.y - d.source.y;
      const length = Math.hypot(dx, dy) || 1;
      const stop = radiusOf(d.target) + 6;
      return `M${d.source.x},${d.source.y}L${d.target.x - (dx / length) * stop},${d.target.y - (dy / length) * stop}`;
    });
    node.attr("transform", (d) => `translate(${d.x},${d.y})`);
  });
  node.call(
    d3
      .drag()
      .on("start", (event, d) => {
        if (!event.active) simulation.alphaTarget(0.25).restart();
        d.fx = d.x;
        d.fy = d.y;
      })
      .on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
      })
      .on("end", (event, d) => {
        if (!event.active) simulation.alphaTarget(0);
        if (growing) {
          store.mapPos[d.id] = [Math.round(d.x), Math.round(d.y)];
          persist();
        } else {
          d.fx = null;
          d.fy = null;
        }
      }),
  );

  const neighbours = (id) =>
    links
      .filter((l) => l.source.id === id || l.target.id === id)
      .map((l) => ({ other: l.source.id === id ? l.target : l.source, link: l, outgoing: l.source.id === id }));
  const isShown = (d) =>
    visibleOnMap.has(d.id) && !view.hiddenGroups.has(groupOf(d)) && view.kinds.has(d.type || "concept");
  const alive = () => document.body.contains(wrap);

  function highlighted() {
    if (view.path) return new Set(view.path);
    if (view.tour >= 0) return new Set(graph.tour[view.tour].nodeIds);
    if (view.selected) return new Set([view.selected, ...neighbours(view.selected).map((n) => n.other.id)]);
    const q = view.query.trim().toLowerCase();
    return q ? new Set(nodes.filter((n) => `${n.name} ${n.summary}`.toLowerCase().includes(q)).map((n) => n.id)) : null;
  }
  function paint() {
    const lit = highlighted();
    const onPath = (d) =>
      view.path &&
      Math.abs(view.path.indexOf(d.source.id) - view.path.indexOf(d.target.id)) === 1 &&
      view.path.includes(d.source.id) &&
      view.path.includes(d.target.id);
    node
      .style("display", (d) => (isShown(d) ? null : "none"))
      .classed("dim", (d) => (lit ? !lit.has(d.id) : false))
      .classed("sel", (d) => d.id === view.selected)
      .classed("hl", (d) => view.tour >= 0 && lit.has(d.id));
    link
      .style("display", (d) => (isShown(d.source) && isShown(d.target) ? null : "none"))
      .classed("dim", (d) => (lit ? !(lit.has(d.source.id) && lit.has(d.target.id)) : false))
      .classed("hl", onPath);
    label.text((d) =>
      view.memory && !view.revealedInMemory.has(d.id) ? "?" : d.name.length > 24 ? `${d.name.slice(0, 22)}…` : d.name,
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
    const connections =
      view.detail === "overview"
        ? ""
        : neighbours(d.id)
            .map(
              ({
                other,
                link: l,
                outgoing,
              }) => `<button class="conn" data-go-node="${esc(other.id)}">${outgoing ? "→" : "←"} ${esc(other.name)}<br>
        <span class="tiny">${esc(l.type.replace(/_/g, " "))}${view.detail === "deep" && l.description ? `: ${esc(l.description)}` : ""}${other.chapter !== d.chapter ? ` · chapter ${other.chapter}` : ""}</span></button>`,
            )
            .join("");
    info.innerHTML = `<div class="row"><span class="pill p-done">${esc(d.type || "concept")}</span><span class="pill p-skip">${esc(d.complexity)}</span></div>
      <h3 style="margin-top:8px">${esc(d.name)}</h3><p class="small">${esc(d.summary)}</p>
      ${view.detail !== "overview" && d.detail ? `<p class="small muted">${esc(d.detail)}</p>` : ""}
      <p class="tiny">From chapter ${d.chapter}: ${esc(chapter?.title || "")}${d.layerName ? ` · ${esc(d.layerName)}` : ""}</p>${connections}
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
      <p class="small">${esc(step.description)}</p><p class="tiny">${step.nodeIds.map((id) => esc(byId[id]?.name || "")).join(" · ")}</p></div>
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
    const around =
      neighbours(d.id)
        .map((n) => (view.revealedInMemory.has(n.other.id) ? esc(n.other.name) : "?"))
        .join(", ") || "nothing";
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

  node
    .on("click", (event, d) => {
      view.selected = view.selected === d.id && !view.memory ? null : d.id;
      view.path = null;
      view.tour = -1;
      paint();
    })
    .on("keydown", (event, d) => {
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
    svg
      .transition()
      .duration(500)
      .call(
        zoom.transform,
        d3.zoomIdentity
          .translate(width / 2 - (scale * (x0 + x1)) / 2, height / 2 - (scale * (y0 + y1)) / 2)
          .scale(scale),
      );
  };
  let saveTimer;
  const savePositions = () => {
    if (!growing) return;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      nodes
        .filter((n) => visibleOnMap.has(n.id))
        .forEach((n) => {
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
    node
      .filter((d) => ids.has(d.id))
      .classed("new", true)
      .each(function stagger(d, i) {
        this.querySelectorAll(".shape, circle, text").forEach((part) => {
          part.style.animationDelay = `${i * 0.07}s`;
        });
      });
    link.filter((d) => ids.has(d.source.id) || ids.has(d.target.id)).classed("new", true);
    paint();
    simulation.alpha(0.7).restart();
    const title = book.chapters.find((c) => c.n === chapterNumber)?.title || "";
    const bridges = links.some((l) => l.type === "similar_to" && ids.has(l.source.id) !== ids.has(l.target.id));
    toast(`🌱 Chapter ${chapterNumber} sprouted ${fresh.length} ideas`);
    info.innerHTML = `<h3>Your map grew!</h3><p class="small">Chapter ${chapterNumber}, “${esc(title)}”, added ${fresh.length} ideas${bridges ? ", and some of them connect to ideas you already knew" : ""}.</p>${pip("hop")}`;
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
        400 + chapters.length * 1900 + 800,
      );
    },
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
      if (view.memory) view.revealedInMemory = new Set();
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
      $("#pres").textContent = path.map((id) => byId[id].name).join(" → ");
    };
  }
}

/** Breadth-first search over connections in either direction. */
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
    <div class="gpanel"><h3>Explore</h3><input type="search" id="gq" placeholder="Search ideas…" aria-label="Search ideas">
      <div class="seg" role="group" aria-label="Detail">${[
        ["overview", "Overview"],
        ["learn", "Learn"],
        ["deep", "Deep dive"],
      ]
        .map(([id, text]) => `<button data-det="${id}" aria-pressed="${id === "learn"}">${text}</button>`)
        .join("")}</div>
      <div><h3 style="margin-bottom:6px">${options.colorBy === "chapter" ? "Chapters" : "Groups"}</h3>
        ${groups.map((_, i) => `<label class="chk"><input type="checkbox" data-grp="${i}" checked><i style="background:${PALETTE[i % PALETTE.length]}"></i>${esc(groupLabel(i))}</label>`).join("")}</div>
      <div><h3 style="margin-bottom:6px">Kinds</h3>${KINDS.map(([id, text]) => `<label class="chk"><input type="checkbox" data-type="${id}" checked>${text}</label>`).join("")}</div>
      <div class="row">${graph.tour?.length ? '<button class="btn sm" id="gtour">Guided tour</button>' : ""}<button class="btn ghost sm" id="gblind">Rebuild from memory</button></div>
      <details><summary class="small"><b>How are two ideas connected?</b></summary>
        <select id="pa" style="margin-top:8px">${nodeOptions}</select><select id="pb" style="margin-top:6px">${nodeOptions}</select>
        <button class="btn sm" id="pgo" style="margin-top:8px">Show path</button><p class="tiny" id="pres"></p></details>
    </div>
    <div class="gcanvas" id="gc"><div class="zoom"><button id="zin" aria-label="Zoom in">+</button><button id="zout" aria-label="Zoom out">−</button><button id="zfit" aria-label="Fit">⤢</button></div></div>
    <div class="gpanel info" id="ginfo" aria-live="polite"></div></div>`;
}
