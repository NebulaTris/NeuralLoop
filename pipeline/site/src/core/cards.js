// Flashcards across the book, limited to unlocked chapters.

import { isUnlocked } from "./loop.js";

export function unlockedCards(chapters, store) {
  return chapters
    .filter((chapter) => isUnlocked(store, chapters, chapter.n))
    .flatMap((chapter) =>
      (chapter.cards || []).map((card, i) => ({ ...card, id: `${chapter.n}:${i}`, chapter: chapter.n })),
    );
}

/** Cards never reviewed, or whose review is due. */
export function dueCards(chapters, store, now) {
  return unlockedCards(chapters, store).filter((card) => {
    const state = store.cards[card.id];
    return !state || state.due <= now;
  });
}
