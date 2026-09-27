// The five-step learning loop for each chapter, and which chapters are unlocked.

export const STAGES = [
  { id: "prime", label: "Listen & watch", verb: "Video and podcast first" },
  { id: "read", label: "Read", verb: "Read with your guide" },
  { id: "recall", label: "Recall", verb: "Recall in your own words" },
  { id: "map", label: "Map", verb: "Remake the map from memory" },
  { id: "space", label: "Remember", verb: "Review your flashcards" },
];

/** A chapter's loop progress: { prime: timestamp, read: timestamp, ... }. */
export function loopOf(store, n) {
  store.loop[n] ??= {};
  return store.loop[n];
}

export function isClosed(store, n) {
  const loop = loopOf(store, n);
  return STAGES.every((stage) => loop[stage.id]);
}

/** The first unfinished step, or null when the loop is closed. */
export function nextStage(store, n) {
  const loop = loopOf(store, n);
  return STAGES.find((stage) => !loop[stage.id])?.id ?? null;
}

/** Chapter 1 is always open; every other chapter opens when the one before it is closed. */
export function isUnlocked(store, chapters, n) {
  const index = chapters.findIndex((c) => c.n === n);
  return index <= 0 || isClosed(store, chapters[index - 1].n);
}

/** Record a finished step. Returns true if this completion closed the loop for the first time. */
export function completeStage(store, n, stageId, now) {
  const loop = loopOf(store, n);
  if (!loop[stageId]) loop[stageId] = now;
  if (isClosed(store, n) && !loop.closedShown) {
    loop.closedShown = true;
    return true;
  }
  return false;
}

/** A chapter's ideas join the book map once its Map step is done. */
export function isMapped(store, n) {
  return Boolean(loopOf(store, n).map);
}
