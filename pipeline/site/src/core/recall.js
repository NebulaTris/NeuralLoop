// Scoring free recall and remaking the mind map from memory.

const STOP_WORDS = new Set(["with", "that", "this", "from", "into", "your", "about", "when", "what", "they", "their"]);

/** 0-3 points for how many key points an answer covered. */
export function recallScore(covered, total) {
  return total ? Math.round((3 * covered) / total) : 0;
}

function significantWords(text) {
  return String(text)
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, " ")
    .split(/\s+/)
    .filter((w) => w.length > 3 && !STOP_WORDS.has(w));
}

/** Does a remembered branch name match the real one? Tolerates word forms and extra words. */
export function namesMatch(guess, truth) {
  const g = guess.toLowerCase().trim();
  const t = truth.toLowerCase().trim();
  if (!g || !t) return false;
  if (g.includes(t) || t.includes(g)) return true;
  const guessWords = significantWords(guess);
  const truthWords = significantWords(truth);
  if (!guessWords.length || !truthWords.length) return false;
  const sameStem = (a, b) => a === b || (a.length > 4 && b.length > 4 && a.slice(0, 5) === b.slice(0, 5));
  const hits = truthWords.filter((tw) => guessWords.some((gw) => sameStem(gw, tw))).length;
  return hits / truthWords.length >= 0.5;
}

/**
 * Compare what someone typed ("Branch" lines, "- sub-idea" lines) with the real mind map.
 * Returns each real branch with whether it (and its sub-ideas) were remembered, and a percentage.
 */
export function compareRemake(typed, mindMap) {
  const lines = typed
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
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
  return { rows, lines, percent: total ? Math.round((100 * found) / total) : 0 };
}
