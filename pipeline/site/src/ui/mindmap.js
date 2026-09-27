// A chapter's mind map as a collapsible tree.

import { $, PALETTE, esc } from "./dom.js";

export function renderMindMap(el, mindMap) {
  el.innerHTML = `<div class="gcanvas mm" id="mm"><div class="gtools"><span class="pill p-done">Tap a branch to fold or unfold it</span></div>
    <div class="zoom"><button id="mmfit" aria-label="Fit">⤢</button></div></div>`;
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
  const zoom = d3
    .zoom()
    .scaleExtent([0.3, 2.5])
    .on("zoom", (event) => layer.attr("transform", event.transform));
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
    links
      .enter()
      .append("path")
      .attr("class", "mmlink")
      .attr("stroke", (link) => link.target.color)
      .merge(links)
      .transition()
      .duration(300)
      .attr("d", curve);
    links.exit().remove();

    const groups = layer.selectAll("g.mmnode").data(nodes, (node) => node.id);
    const entering = groups
      .enter()
      .append("g")
      .attr("class", "mmnode")
      .attr("transform", `translate(${from.y0},${from.x0})`)
      .on("click", (event, node) => {
        [node.children, node.hidden] = node.children ? [null, node.children] : [node.hidden, null];
        update(node);
      });
    entering.append("rect");
    entering.append("text").attr("dy", "0.35em").attr("x", 12);
    const all = entering.merge(groups);
    all.select("text").text((node) => node.data.name + (node.hidden ? "  +" : ""));
    all.each(function sizeBox(node) {
      const width = Math.min(260, this.querySelector("text").getComputedTextLength() + 24);
      d3.select(this)
        .select("rect")
        .attr("x", 0)
        .attr("y", -15)
        .attr("width", width)
        .attr("height", 30)
        .attr("fill", node.depth === 0 ? "var(--accent-soft)" : "var(--surface)")
        .attr("stroke", node.color);
    });
    all
      .transition()
      .duration(300)
      .attr("transform", (node) => `translate(${node.y},${node.x})`);
    groups.exit().remove();
    nodes.forEach((node) => {
      node.x0 = node.x;
      node.y0 = node.y;
    });
  };
  update(root);
  const fit = () =>
    svg
      .transition()
      .duration(400)
      .call(zoom.transform, d3.zoomIdentity.translate(60, wrap.clientHeight / 2));
  fit();
  $("#mmfit").onclick = fit;
}
