// Where each chapter's ideas sprout on the growing book map.

const GOLDEN_ANGLE = 2.39996;
const RING_SPACING = 150;

/** Chapter k (0-based, in the order chapters were mapped) sprouts on a golden-angle spiral. */
export function sproutPoint(k, centerX, centerY) {
  if (k <= 0) return [centerX, centerY];
  const angle = k * GOLDEN_ANGLE;
  const radius = RING_SPACING * Math.sqrt(k);
  return [centerX + radius * Math.cos(angle), centerY + radius * Math.sin(angle)];
}
