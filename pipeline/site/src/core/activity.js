// The daily study log: seconds studied per local day, a year-long calendar grid, and encouraging stats.

const DAY_MS = 86_400_000;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
// Minutes that start each level: a little, a solid session, a deep one, a big day.
const LEVEL_STARTS = [0, 10 * 60, 20 * 60, 45 * 60];

/** Local calendar date as YYYY-MM-DD. */
export function dayKey(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function logActivity(store, now, seconds) {
  store.log ||= {};
  const day = dayKey(now);
  store.log[day] = (store.log[day] || 0) + seconds;
}

export function studyLevel(seconds) {
  if (!seconds) return 0;
  return LEVEL_STARTS.filter((start) => seconds >= start).length;
}

const midnight = (ms) => new Date(new Date(ms).setHours(0, 0, 0, 0)).getTime();
const addDays = (ms, n) => {
  const d = new Date(ms);
  d.setDate(d.getDate() + n);
  return d.getTime();
};

/** 53 weeks of 7 days (Sunday first), ending with this week, plus where each month's label goes. */
export function yearGrid(log = {}, today = Date.now()) {
  const end = midnight(today);
  const start = addDays(end, -(52 * 7 + new Date(end).getDay()));
  const weeks = [];
  const months = [];
  for (let w = 0; w < 53; w++) {
    const week = [];
    for (let d = 0; d < 7; d++) {
      const ms = addDays(start, w * 7 + d);
      const date = dayKey(ms);
      const seconds = log[date] || 0;
      week.push({ date, seconds, level: studyLevel(seconds), future: ms > end });
    }
    const first = new Date(addDays(start, w * 7));
    const previous = new Date(addDays(start, (w - 1) * 7));
    if (w === 0 || first.getMonth() !== previous.getMonth()) months.push({ week: w, label: MONTHS[first.getMonth()] });
    weeks.push(week);
  }
  return { weeks, months: months[1] && months[1].week - months[0].week < 3 ? months.slice(1) : months };
}

/** Totals for the last 365 days. Only positive framing: no "streak lost". */
export function yearStats(log = {}, today = Date.now()) {
  const end = midnight(today);
  let total = 0;
  let days = 0;
  let run = 0;
  let longestRun = 0;
  let best = null;
  for (let i = 364; i >= 0; i--) {
    const date = dayKey(addDays(end, -i));
    const seconds = log[date] || 0;
    total += seconds;
    if (seconds > 0) {
      days++;
      run++;
      longestRun = Math.max(longestRun, run);
      if (!best || seconds > best.seconds) best = { date, seconds };
    } else {
      run = 0;
    }
  }
  return { total, days, longestRun, best };
}

export function formatDuration(seconds) {
  const minutes = seconds > 0 ? Math.max(1, Math.round(seconds / 60)) : 0;
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`;
}

/** "Mon, 28 Sep" for tooltips. */
export function formatDay(date) {
  const [y, m, d] = date.split("-").map(Number);
  const weekday = new Date(y, m - 1, d).toLocaleDateString("en", { weekday: "short" });
  return `${weekday}, ${d} ${MONTHS[m - 1]}`;
}

export { DAY_MS };
