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

/** Drop the chapter's own title if the text repeats it as its first heading(s). */
export function withoutRepeatedTitle(text, title) {
  return text.replace(/^(\s*#{1,3}\s+[^\n]*\n+){1,2}/, (headings) =>
    headings.toLowerCase().includes(title.toLowerCase()) ? "" : headings,
  );
}

/** Markdown paragraphs and headings to HTML; headings that match the reading plan get a label and a note. */
export function markdownToHtml(text, guide = []) {
  const plan = guide.map((entry) => ({ ...entry, key: entry.section.toLowerCase().trim() }));
  return text
    .split(/\n{2,}/)
    .map((block) => {
      const trimmed = block.trim();
      if (!trimmed) return "";
      const heading = trimmed.match(/^(#{1,3})\s+(.*)/);
      if (!heading) return `<p>${escapeHtml(trimmed).replace(/\n/g, " ")}</p>`;
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
