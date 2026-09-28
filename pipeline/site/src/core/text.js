// Escaping and turning chapter Markdown into reader HTML with reading-plan labels.

export function escapeHtml(value) {
  return String(value ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}

const LEVEL = {
  deep: { pill: "p-fail", label: "Deep read" },
  skim: { pill: "p-skip", label: "Skim" },
  normal: { pill: "p-done", label: "Read" },
};

export function levelLabel(level) {
  return LEVEL[level] || LEVEL.normal;
}

/** Who made the book's study material, for the header. */
export function madeWith(book) {
  const engine = book.engine || "notebooklm";
  if (book.provider === "fake" || book.dryRun) return "a practice run";
  if (engine === "notebooklm") return "made with NotebookLM";
  const model = book.model || book.provider || "your AI";
  return engine === "auto" ? `made with NotebookLM and ${model}` : `made with ${model}`;
}

/** Drop the chapter's own title if the text repeats it as its first heading(s). */
export function withoutRepeatedTitle(text, title) {
  return text.replace(/^(\s*#{1,3}\s+[^\n]*\n+){1,2}/, (headings) =>
    headings.toLowerCase().includes(title.toLowerCase()) ? "" : headings,
  );
}

// Only images the pipeline copied next to the chapter (chapters/img/NN-KK.ext) are shown.
const FIGURE = /^!\[([^\]]*)\]\((img\/[\w.-]+\.(?:png|jpe?g|gif|svg|webp))\)$/i;
const ANY_IMAGE = /^!\[[^\]]*\]\([^)]*\)$/;
const CAPTION = /^\*([^*].*[^*])\*$/;

/** Escaped text with *emphasis* and **bold**. */
function inline(text) {
  return escapeHtml(text)
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/\n/g, " ");
}

/** Markdown to textbook-style HTML: headings (reading-plan labels and notes), figures with captions, lists. */
export function markdownToHtml(text, guide = []) {
  const plan = guide.map((entry) => ({ ...entry, key: entry.section.toLowerCase().trim() }));
  const blocks = text.split(/\n{2,}/).map((block) => block.trim());
  return blocks
    .map((trimmed, i) => {
      if (!trimmed) return "";
      const figure = trimmed.match(FIGURE);
      if (figure) {
        const caption = (blocks[i + 1] || "").match(CAPTION);
        const img = `<img src="chapters/${figure[2]}" alt="${escapeHtml(figure[1])}" loading="lazy">`;
        return `<figure>${img}${caption ? `<figcaption>${inline(caption[1])}</figcaption>` : ""}</figure>`;
      }
      if (ANY_IMAGE.test(trimmed)) return "";
      const previous = (blocks[i - 1] || "").match(FIGURE);
      if (previous && CAPTION.test(trimmed)) return ""; // already shown as the figure's caption
      if (/^- /.test(trimmed)) {
        const items = trimmed.split(/\n- /).map((item) => `<li>${inline(item.replace(/^- /, ""))}</li>`);
        return `<ul>${items.join("")}</ul>`;
      }
      const heading = trimmed.match(/^(#{1,3})\s+(.*)/);
      if (!heading) return `<p>${inline(trimmed)}</p>`;
      const title = heading[2].trim();
      const lower = title.toLowerCase();
      const match = plan.find((p) => p.key && (lower.includes(p.key) || p.key.includes(lower)));
      const tag = heading[1].length === 1 ? "h2" : "h3";
      const pill = match
        ? ` <span class="pill ${levelLabel(match.level).pill}">${levelLabel(match.level).label}</span>`
        : "";
      const note = match ? `<p class="gnote">${escapeHtml(match.why)}</p>` : "";
      return `<${tag}>${escapeHtml(title)}${pill}</${tag}>${note}`;
    })
    .join("");
}
