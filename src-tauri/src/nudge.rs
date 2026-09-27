//! Pip's gentle nudges: at most one a day, only when something small is worth doing.
//!
//! `decide` is a pure function so the whole policy is unit-tested; `tick` gathers the inputs
//! from disk and shows the notification.

use crate::library::STAGES;
use crate::settings::{self, Settings};
use crate::storage::{books_root, config_file, now_ms, read_json, write_json};
use chrono::{Datelike, Local, TimeZone, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tauri_plugin_notification::NotificationExt;

const DAY_MS: i64 = 86_400_000;
const MIN_DUE_CARDS: u64 = 3;
const SECONDS_PER_CARD: u64 = 15;
const HALF_DONE_AFTER_MS: i64 = DAY_MS / 2;
const NEXT_STEP: [&str; 5] =
    ["watch or listen", "read with your guide", "recall it in your own words", "remake the map from memory", "review your flashcards"];

#[derive(Serialize, Deserialize, Default, Debug, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct NudgeHistory {
    pub last_sent: i64,
    pub last_sent_day: String,
    pub last_engaged: i64,
    pub ignored_in_a_row: u32,
}

/// One book as the nudge policy sees it.
pub struct BookProgress {
    pub state: Value,
    pub progress: Value,
}

#[derive(Debug, PartialEq)]
pub struct Nudge {
    pub title: String,
    pub body: String,
}

/// Cards reviewed at least once whose next review is due. Never-seen cards don't count.
pub fn reviewed_cards_due(progress: &Value, now: i64) -> u64 {
    progress["cards"]
        .as_object()
        .map(|cards| {
            cards.values().filter(|c| c["reps"].as_i64().unwrap_or(0) > 0 && c["due"].as_i64().unwrap_or(i64::MAX) <= now).count() as u64
        })
        .unwrap_or(0)
}

pub fn in_quiet_hours(hour: u32, start: u32, end: u32) -> bool {
    match start.cmp(&end) {
        std::cmp::Ordering::Equal => false,
        std::cmp::Ordering::Greater => hour >= start || hour < end, // wraps past midnight, e.g. 22-08
        std::cmp::Ordering::Less => hour >= start && hour < end,
    }
}

/// Should Pip nudge now, and with what? `today` is the local date, `hour` the local hour.
pub fn decide(books: &[BookProgress], settings: &Settings, history: &NudgeHistory, now: i64, hour: u32, today: &str) -> Option<Nudge> {
    if !settings.nudges || now < settings.paused_until || in_quiet_hours(hour, settings.quiet_start, settings.quiet_end) {
        return None;
    }
    if history.last_sent_day == today {
        return None; // at most one a day
    }
    if history.ignored_in_a_row >= 2 && now - history.last_sent < 2 * DAY_MS {
        return None; // ignored twice: every other day at most
    }
    let away_a_week = history.last_engaged > 0 && now - history.last_engaged > 7 * DAY_MS;
    if away_a_week && now - history.last_sent < 7 * DAY_MS {
        return None; // away a week: weekly only
    }
    due_cards_nudge(books, now).or_else(|| half_done_chapter_nudge(books, now))
}

fn due_cards_nudge(books: &[BookProgress], now: i64) -> Option<Nudge> {
    let due: u64 = books.iter().map(|b| reviewed_cards_due(&b.progress, now)).sum();
    (due >= MIN_DUE_CARDS).then(|| Nudge {
        title: format!("🐾 {due} cards are ready"),
        body: format!("About {} min with Pip, then you're done for today.", (due * SECONDS_PER_CARD).div_ceil(60)),
    })
}

/// The most recently touched chapter left partway through its loop for at least half a day.
fn half_done_chapter_nudge(books: &[BookProgress], now: i64) -> Option<Nudge> {
    let mut best: Option<(i64, String, &str)> = None;
    for book in books {
        for (chapter, stages) in book.progress["loop"].as_object().into_iter().flatten() {
            let done: Vec<i64> = STAGES.iter().filter_map(|s| stages.get(*s).and_then(Value::as_i64)).collect();
            if done.is_empty() || done.len() == STAGES.len() {
                continue;
            }
            let last_touched = done.iter().copied().max().unwrap_or(0);
            if now - last_touched < HALF_DONE_AFTER_MS || best.as_ref().is_some_and(|b| b.0 >= last_touched) {
                continue;
            }
            let next = STAGES.iter().position(|s| stages.get(*s).is_none()).map_or("keep going", |i| NEXT_STEP[i]);
            let title = book.state["chapters"]
                .as_array()
                .and_then(|all| all.iter().find(|c| c["n"].as_i64().map(|n| n.to_string()).as_deref() == Some(chapter.as_str())))
                .and_then(|c| c["title"].as_str())
                .unwrap_or("your chapter")
                .to_string();
            best = Some((last_touched, title, next));
        }
    }
    best.map(|(_, title, next)| Nudge {
        title: format!("🧶 Loose yarn in “{title}”"), body: format!("Next: {next}. Pip saved your spot.")
    })
}

fn history_file(app: &AppHandle) -> std::path::PathBuf {
    config_file(app, "nudges.json")
}

fn load_history(app: &AppHandle) -> NudgeHistory {
    serde_json::from_value(read_json(&history_file(app))).unwrap_or_default()
}

fn save_history(app: &AppHandle, history: &NudgeHistory) {
    let _ = write_json(&history_file(app), &serde_json::to_value(history).unwrap_or(Value::Null));
}

/// Called every few minutes by the background loop.
pub fn tick(app: &AppHandle) {
    let books: Vec<BookProgress> = std::fs::read_dir(books_root(app))
        .map(|entries| {
            entries
                .flatten()
                .map(|e| BookProgress {
                    state: read_json(&e.path().join("state.json")),
                    progress: read_json(&e.path().join("progress.json")),
                })
                .collect()
        })
        .unwrap_or_default();
    let mut history = load_history(app);
    let local = Local::now();
    let today = local.format("%Y-%m-%d").to_string();
    let Some(nudge) = decide(&books, &settings::load(app), &history, now_ms(), local.hour(), &today) else { return };
    let previous_was_ignored = history.last_sent > 0 && history.last_engaged < history.last_sent;
    history.ignored_in_a_row = if previous_was_ignored { history.ignored_in_a_row + 1 } else { 0 };
    history.last_sent = now_ms();
    history.last_sent_day = today;
    save_history(app, &history);
    let _ = app.notification().builder().title(&nudge.title).body(&nudge.body).show();
    let _ = app.emit("nudge", json!({ "title": nudge.title, "body": nudge.body }));
}

/// The person opened or focused the app: they're engaged, so reset the back-off.
#[tauri::command]
pub fn nudge_engaged(app: AppHandle) {
    let mut history = load_history(&app);
    history.last_engaged = now_ms();
    history.ignored_in_a_row = 0;
    save_history(&app, &history);
}

pub fn pause_until_tomorrow(app: &AppHandle) {
    let mut s = settings::load(app);
    let tomorrow = Local::now() + chrono::Duration::days(1);
    s.paused_until = Local
        .with_ymd_and_hms(tomorrow.year(), tomorrow.month(), tomorrow.day(), s.quiet_end.min(23), 0, 0)
        .single()
        .map_or(now_ms() + DAY_MS, |t| t.timestamp_millis());
    let _ = settings::save(app, &s);
    let _ = app.emit("toast", "Nudges paused until tomorrow. Pip will be quiet.");
}

#[tauri::command]
pub fn pause_nudges_today(app: AppHandle) {
    pause_until_tomorrow(&app)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 10 * DAY_MS;

    fn with_due_cards(reps: i64, count: usize) -> BookProgress {
        let cards: serde_json::Map<String, Value> =
            (0..count).map(|i| (format!("1:{i}"), json!({ "due": NOW - 1, "reps": reps }))).collect();
        BookProgress { state: json!({}), progress: json!({ "cards": cards, "loop": {} }) }
    }

    fn decide_now(books: &[BookProgress], history: &NudgeHistory, hour: u32) -> Option<Nudge> {
        decide(books, &Settings::default(), history, NOW, hour, "day-1")
    }

    #[test]
    fn quiet_hours_wrap_past_midnight() {
        assert!(in_quiet_hours(23, 22, 8) && in_quiet_hours(3, 22, 8));
        assert!(!in_quiet_hours(12, 22, 8) && !in_quiet_hours(9, 9, 9));
    }

    #[test]
    fn three_or_more_due_cards_are_worth_a_nudge() {
        let nudge = decide_now(&[with_due_cards(1, 4)], &NudgeHistory::default(), 18).expect("a nudge");
        assert_eq!(nudge.title, "🐾 4 cards are ready");
        assert!(nudge.body.contains("1 min"));
        assert!(decide_now(&[with_due_cards(1, 2)], &NudgeHistory::default(), 18).is_none());
    }

    #[test]
    fn cards_never_reviewed_are_not_due() {
        assert!(decide_now(&[with_due_cards(0, 10)], &NudgeHistory::default(), 18).is_none());
    }

    #[test]
    fn at_most_one_a_day_never_in_quiet_hours_and_off_means_off() {
        let books = [with_due_cards(1, 5)];
        let sent_today = NudgeHistory { last_sent_day: "day-1".into(), ..Default::default() };
        assert!(decide_now(&books, &sent_today, 18).is_none());
        assert!(decide_now(&books, &NudgeHistory::default(), 23).is_none());
        let off = Settings { nudges: false, ..Settings::default() };
        assert!(decide(&books, &off, &NudgeHistory::default(), NOW, 18, "day-1").is_none());
    }

    #[test]
    fn backs_off_after_two_ignored_nudges() {
        let books = [with_due_cards(1, 5)];
        let recent = NudgeHistory { ignored_in_a_row: 2, last_sent: NOW - DAY_MS, last_sent_day: "day-0".into(), ..Default::default() };
        assert!(decide_now(&books, &recent, 18).is_none());
        let older = NudgeHistory { last_sent: NOW - 3 * DAY_MS, ..recent };
        assert!(decide_now(&books, &older, 18).is_some());
    }

    #[test]
    fn away_a_week_means_weekly_only() {
        let books = [with_due_cards(1, 5)];
        let away = NudgeHistory {
            last_engaged: NOW - 9 * DAY_MS,
            last_sent: NOW - 3 * DAY_MS,
            last_sent_day: "day-0".into(),
            ..Default::default()
        };
        assert!(decide_now(&books, &away, 18).is_none());
    }

    #[test]
    fn a_half_done_chapter_gets_a_loose_yarn_nudge() {
        let book = BookProgress {
            state: json!({ "chapters": [{ "n": 1, "title": "One" }, { "n": 2, "title": "Queues" }] }),
            progress: json!({ "cards": {}, "loop": { "2": { "prime": NOW - DAY_MS, "read": NOW - DAY_MS } } }),
        };
        let nudge = decide_now(&[book], &NudgeHistory::default(), 18).expect("a nudge");
        assert_eq!(nudge.title, "🧶 Loose yarn in “Queues”");
        assert!(nudge.body.contains("recall it in your own words"));
    }
}
