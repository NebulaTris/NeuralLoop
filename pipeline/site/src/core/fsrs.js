// FSRS-4.5 spaced-repetition scheduler (the same rules as the NeuralLoop engine).

const WEIGHTS = [
  0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587,
  0.2272, 2.8755,
];
const DECAY = -0.5;
const FACTOR = 19 / 81;
export const DAY_MS = 86_400_000;
const RELEARN_MS = 10 * 60_000;
const MAX_INTERVAL_DAYS = 365;

const clampDifficulty = (d) => Math.min(10, Math.max(1, d));

export function retrievability(elapsedDays, stability) {
  return Math.pow(1 + (FACTOR * elapsedDays) / stability, DECAY);
}

/** Grade a card (1 again, 2 hard, 3 good, 4 easy) at time `now`; returns the updated card state. */
export function grade(card, rating, now) {
  const w = WEIGHTS;
  const next = { ...card };
  if (!card.reps) {
    next.s = w[rating - 1];
    next.d = clampDifficulty(w[4] - (rating - 3) * w[5]);
  } else {
    const r = retrievability((now - card.last) / DAY_MS, card.s);
    const d = card.d;
    next.d = clampDifficulty(w[7] * (w[4] - w[5]) + (1 - w[7]) * (d - w[6] * (rating - 3)));
    if (rating === 1) {
      next.s = w[11] * Math.pow(d, -w[12]) * (Math.pow(card.s + 1, w[13]) - 1) * Math.exp(w[14] * (1 - r));
    } else {
      const hardPenalty = rating === 2 ? w[15] : 1;
      const easyBonus = rating === 4 ? w[16] : 1;
      next.s =
        card.s *
        (1 +
          Math.exp(w[8]) *
            (11 - d) *
            Math.pow(card.s, -w[9]) *
            (Math.exp(w[10] * (1 - r)) - 1) *
            hardPenalty *
            easyBonus);
    }
  }
  next.s = Math.max(0.1, next.s);
  next.reps = (card.reps || 0) + 1;
  next.last = now;
  next.due =
    rating === 1 ? now + RELEARN_MS : now + Math.min(MAX_INTERVAL_DAYS, Math.max(1, Math.round(next.s))) * DAY_MS;
  return next;
}

/** "10 min", "3 h", "4 d": how long until `due`. */
export function formatWait(due, now) {
  const ms = due - now;
  if (ms < 3_600_000) return `${Math.max(1, Math.round(ms / 60_000))} min`;
  if (ms < DAY_MS) return `${Math.round(ms / 3_600_000)} h`;
  return `${Math.round(ms / DAY_MS)} d`;
}
