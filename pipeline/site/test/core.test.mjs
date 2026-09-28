import assert from "node:assert/strict";
import { test } from "node:test";

import { unlockedCards, dueCards } from "../src/core/cards.js";
import { DAY_MS, formatWait, grade } from "../src/core/fsrs.js";
import { sproutPoint } from "../src/core/growth.js";
import { STAGES, completeStage, isMapped, isUnlocked, nextStage } from "../src/core/loop.js";
import { compareRemake, namesMatch, recallScore } from "../src/core/recall.js";
import { escapeHtml, madeWith, markdownToHtml, withoutRepeatedTitle } from "../src/core/text.js";

const emptyStore = () => ({ loop: {}, cards: {} });
const book = [
  { n: 1, cards: [{ front: "a", back: "b" }] },
  { n: 2, cards: [{ front: "c", back: "d" }] },
];

test("new cards follow FSRS-4.5 starting stability: Good about 4 days, Easy 14 days", () => {
  assert.equal(Math.round(grade({}, 3, 0).due / DAY_MS), 4);
  assert.equal(Math.round(grade({}, 4, 0).due / DAY_MS), 14);
});

test("Again brings a card back in 10 minutes", () => {
  const reviewed = grade(grade({}, 3, 0), 1, 5 * DAY_MS);
  assert.equal(reviewed.due - 5 * DAY_MS, 10 * 60_000);
  assert.equal(reviewed.reps, 2);
});

test("remembering again on schedule grows the interval", () => {
  const first = grade({}, 3, 0);
  const second = grade(first, 3, first.due);
  assert.ok(second.due - first.due > first.due);
});

test("formatWait", () => {
  assert.equal(formatWait(10 * 60_000, 0), "10 min");
  assert.equal(formatWait(3 * 3_600_000, 0), "3 h");
  assert.equal(formatWait(4 * DAY_MS, 0), "4 d");
});

test("the loop moves through the five steps and reports closing once", () => {
  const store = emptyStore();
  assert.equal(nextStage(store, 1), "prime");
  const closings = STAGES.map((s) => completeStage(store, 1, s.id, 1));
  assert.deepEqual(closings, [false, false, false, false, true]);
  assert.equal(nextStage(store, 1), null);
  assert.equal(completeStage(store, 1, "space", 2), false);
});

test("chapter 2 unlocks only after chapter 1's loop is closed", () => {
  const store = emptyStore();
  assert.equal(isUnlocked(store, book, 1), true);
  assert.equal(isUnlocked(store, book, 2), false);
  STAGES.forEach((s) => completeStage(store, 1, s.id, 1));
  assert.equal(isUnlocked(store, book, 2), true);
});

test("locked chapters' cards stay out of review", () => {
  const store = emptyStore();
  assert.deepEqual(
    unlockedCards(book, store).map((c) => c.id),
    ["1:0"],
  );
  store.cards["1:0"] = { due: 100 };
  assert.equal(dueCards(book, store, 50).length, 0);
  assert.equal(dueCards(book, store, 150).length, 1);
});

test("a chapter joins the book map after its Map step", () => {
  const store = emptyStore();
  assert.equal(isMapped(store, 1), false);
  completeStage(store, 1, "map", 1);
  assert.equal(isMapped(store, 1), true);
});

test("recall score", () => {
  assert.equal(recallScore(2, 3), 2);
  assert.equal(recallScore(0, 0), 0);
});

test("names match across word forms but not unrelated words", () => {
  assert.ok(namesMatch("Practice", "In practice"));
  assert.ok(namesMatch("monitoring things", "Monitoring"));
  assert.ok(!namesMatch("Testing", "Failure modes"));
});

test("remaking the map scores branches and sub-ideas", () => {
  const map = {
    name: "Root",
    children: [{ name: "Foundations", children: [{ name: "Key terms" }] }, { name: "Takeaways" }],
  };
  const result = compareRemake("Foundations\n- key terms\nSomething else", map);
  assert.deepEqual(
    result.rows.map((r) => r.remembered),
    [true, false],
  );
  assert.equal(result.rows[0].children[0].remembered, true);
  assert.equal(result.percent, 67);
});

test("chapters sprout further out on a spiral", () => {
  assert.deepEqual(sproutPoint(0, 100, 100), [100, 100]);
  const [x1, y1] = sproutPoint(1, 100, 100);
  const [x4, y4] = sproutPoint(4, 100, 100);
  assert.ok(Math.hypot(x4 - 100, y4 - 100) > Math.hypot(x1 - 100, y1 - 100));
});

test("escapeHtml and the reader", () => {
  assert.equal(escapeHtml('<a href="x">'), "&lt;a href=&quot;x&quot;&gt;");
  const html = markdownToHtml("## Part one\n\nText <b>here</b>.", [
    { section: "Part one", level: "deep", why: "Core idea" },
  ]);
  assert.match(html, /<h3>Part one <span class="pill p-fail">Deep read<\/span><\/h3><p class="gnote">Core idea<\/p>/);
  assert.match(html, /<p>Text &lt;b&gt;here&lt;\/b&gt;.<\/p>/);
  assert.equal(withoutRepeatedTitle("# Caching\n\n## Part", "Caching"), "## Part");
});

test("reader shows figures, emphasis, and lists like a textbook", () => {
  const html = markdownToHtml(
    "![A cache](img/01-01.png)\n\n*Figure 1. Reads hit the cache.*\n\nThis is *key* and **vital**.\n\n- One\n- Two",
  );
  assert.match(html, /<figure><img src="chapters\/img\/01-01.png" alt="A cache" loading="lazy">/);
  assert.match(html, /<figcaption>Figure 1. Reads hit the cache.<\/figcaption><\/figure>/);
  assert.match(html, /<p>This is <em>key<\/em> and <strong>vital<\/strong>.<\/p>/);
  assert.match(html, /<ul><li>One<\/li><li>Two<\/li><\/ul>/);
});

test("reader refuses image paths outside the chapter's images", () => {
  const html = markdownToHtml('![x](javascript:alert(1))\n\n![y](../../secret.png)\n\n![z](img/a" onerror="x.png)');
  assert.doesNotMatch(html, /<img/);
});

test("the header credits whoever really made the book", () => {
  assert.equal(madeWith({ engine: "notebooklm" }), "made with NotebookLM");
  assert.equal(madeWith({ engine: "local", model: "qwen3:8b" }), "made with qwen3:8b");
  assert.equal(madeWith({ engine: "auto", model: "qwen3:8b" }), "made with NotebookLM and qwen3:8b");
  assert.equal(madeWith({}), "made with NotebookLM");
  assert.equal(madeWith({ engine: "local", model: "", provider: "fake" }), "a practice run");
});
