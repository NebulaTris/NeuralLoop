// "Your year with Pip": a calendar heatmap of time studied per day, with encouraging totals and a table view.

import { formatDay, formatDuration, yearGrid, yearStats } from "../core/activity.js";
import { store } from "./context.js";
import { $, esc } from "./dom.js";

const CELL = 12;
const GAP = 3;
const LEFT = 30;
const TOP = 18;
const DAYS = ["", "Mon", "", "Wed", "", "Fri", ""];
const LEVELS = ["No study", "A little", "A solid session", "A deep session", "A big day"];

export function yearLogCard() {
  const grid = yearGrid(store.log);
  const stats = yearStats(store.log);
  const width = LEFT + grid.weeks.length * (CELL + GAP);
  const height = TOP + 7 * (CELL + GAP);
  const cells = grid.weeks
    .map((week, w) =>
      week
        .filter((day) => !day.future)
        .map(
          (day) =>
            `<rect class="heat h${day.level}" x="${LEFT + w * (CELL + GAP)}" y="${TOP + new Date(day.date + "T12:00").getDay() * (CELL + GAP)}"
              width="${CELL}" height="${CELL}" rx="3" data-date="${day.date}" data-seconds="${day.seconds}"></rect>`,
        )
        .join(""),
    )
    .join("");
  const months = grid.months
    .map((m) => `<text class="axis" x="${LEFT + m.week * (CELL + GAP)}" y="11">${m.label}</text>`)
    .join("");
  const days = DAYS.map((d, i) =>
    d ? `<text class="axis" x="0" y="${TOP + i * (CELL + GAP) + CELL - 2}">${d}</text>` : "",
  ).join("");
  const best = stats.best ? `${formatDuration(stats.best.seconds)} on ${formatDay(stats.best.date)}` : "Still to come";
  return `
    <section class="card yearlog" aria-labelledby="yeartitle">
      <div class="yearhead">
        <h3 id="yeartitle">Your year with Pip</h3>
        <button class="btn ghost sm" id="yeartable" aria-pressed="false">Show as table</button>
      </div>
      <div class="yearstats">
        ${yearStat(formatDuration(stats.total), "studied this year")}
        ${yearStat(stats.days, stats.days === 1 ? "day with study" : "days with study")}
        ${yearStat(stats.longestRun, "longest run of days")}
        ${yearStat(best, "your best day")}
      </div>
      <div class="heatwrap" id="heatwrap">
        <svg class="heatmap" id="heatmap" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" tabindex="0"
          role="img" aria-label="Time studied each day this year. ${esc(formatDuration(stats.total))} in total. Use the arrow keys to read days.">
          ${months}${days}${cells}<rect id="heatfocus" class="heatfocus" width="${CELL + 4}" height="${CELL + 4}" rx="4" hidden></rect>
        </svg>
        <div class="heattip" id="heattip" role="status" hidden></div>
      </div>
      <div class="heatkey" aria-hidden="true"><span>Less</span>${[0, 1, 2, 3, 4].map((l) => `<i class="h${l}" title="${LEVELS[l]}"></i>`).join("")}<span>More</span></div>
      <div class="heattable" id="heattablebox" hidden>${monthTable(store.log)}</div>
    </section>`;
}

const yearStat = (value, label) => `<div><b>${esc(String(value))}</b><span class="tiny">${label}</span></div>`;

function monthTable(log = {}) {
  const rows = {};
  for (const [date, seconds] of Object.entries(log)) {
    const key = date.slice(0, 7);
    rows[key] ||= { days: 0, seconds: 0 };
    rows[key].days += seconds > 0 ? 1 : 0;
    rows[key].seconds += seconds;
  }
  const body = Object.keys(rows)
    .sort()
    .reverse()
    .slice(0, 12)
    .map((key) => {
      const [y, m] = key.split("-").map(Number);
      const name = new Date(y, m - 1, 1).toLocaleDateString("en", { month: "long", year: "numeric" });
      return `<tr><td>${name}</td><td class="num">${rows[key].days}</td><td class="num">${formatDuration(rows[key].seconds)}</td></tr>`;
    })
    .join("");
  return body
    ? `<table><thead><tr><th>Month</th><th>Days</th><th>Time</th></tr></thead><tbody>${body}</tbody></table>`
    : `<p class="muted">Your study time shows up here as you go.</p>`;
}

/** Hover and keyboard reading of the heatmap. */
export function wireYearLog(root) {
  const svg = $("#heatmap", root);
  if (!svg) return;
  const tip = $("#heattip", root);
  const focus = $("#heatfocus", root);
  const cells = [...svg.querySelectorAll("rect.heat")];
  let active = cells.length - 1;
  const show = (cell) => {
    const seconds = Number(cell.dataset.seconds);
    tip.textContent = `${formatDay(cell.dataset.date)} · ${seconds ? formatDuration(seconds) : "no study"}`;
    tip.hidden = false;
    const box = svg.getBoundingClientRect();
    const scale = box.width / svg.viewBox.baseVal.width;
    const x = Number(cell.getAttribute("x")) * scale;
    const y = Number(cell.getAttribute("y")) * scale;
    tip.style.left = `${Math.min(Math.max(x - 60, 0), box.width - 170)}px`;
    tip.style.top = `${y - 34}px`;
    focus.setAttribute("x", Number(cell.getAttribute("x")) - 2);
    focus.setAttribute("y", Number(cell.getAttribute("y")) - 2);
    focus.hidden = false;
  };
  const hide = () => {
    tip.hidden = true;
    focus.hidden = true;
  };
  svg.addEventListener("pointermove", (event) => {
    const cell = event.target.closest?.("rect.heat");
    if (cell) {
      active = cells.indexOf(cell);
      show(cell);
    }
  });
  svg.addEventListener("pointerleave", hide);
  svg.addEventListener("focus", () => show(cells[active]));
  svg.addEventListener("blur", hide);
  svg.addEventListener("keydown", (event) => {
    const step = { ArrowLeft: -7, ArrowRight: 7, ArrowUp: -1, ArrowDown: 1 }[event.key];
    if (!step) return;
    event.preventDefault();
    active = Math.min(Math.max(active + step, 0), cells.length - 1);
    show(cells[active]);
  });
  const toggle = $("#yeartable", root);
  toggle.onclick = () => {
    const table = $("#heattablebox", root);
    const on = table.hidden;
    table.hidden = !on;
    $("#heatwrap", root).hidden = on;
    toggle.setAttribute("aria-pressed", String(on));
    toggle.textContent = on ? "Show as chart" : "Show as table";
  };
}
