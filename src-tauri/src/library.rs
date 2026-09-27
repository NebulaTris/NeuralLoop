//! The book shelf: listing, removing, and saving study progress reported by the study site.

use crate::nudge::reviewed_cards_due;
use crate::pipeline::Jobs;
use crate::storage::{books_root, now_ms, read_json, valid_id, write_json};
use serde_json::{json, Value};
use std::collections::HashMap;
use tauri::AppHandle;

pub const STAGES: [&str; 5] = ["prime", "read", "recall", "map", "space"];

/// How many chapters have all five loop steps done.
pub fn loops_closed(progress: &Value) -> usize {
    progress["loop"]
        .as_object()
        .map(|loops| loops.values().filter(|stages| STAGES.iter().all(|s| stages.get(*s).is_some())).count())
        .unwrap_or(0)
}

/// Count of each task status across a book's chapters, e.g. {"done": 23, "skipped": 5}.
pub fn status_counts(state: &Value) -> HashMap<String, u32> {
    let mut counts = HashMap::new();
    for chapter in state["chapters"].as_array().into_iter().flatten() {
        for task in chapter["tasks"].as_object().into_iter().flat_map(|t| t.values()) {
            *counts.entry(task["status"].as_str().unwrap_or("todo").to_string()).or_default() += 1;
        }
    }
    counts
}

#[tauri::command]
pub fn list_books(app: AppHandle, jobs: tauri::State<'_, Jobs>) -> Vec<Value> {
    let running = jobs.running_ids();
    let Ok(entries) = std::fs::read_dir(books_root(&app)) else { return vec![] };
    let mut books: Vec<Value> = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| {
            let id = entry.file_name().to_string_lossy().to_string();
            valid_id(&id).then(|| {
                let dir = entry.path();
                let (state, meta, progress) =
                    (read_json(&dir.join("state.json")), read_json(&dir.join("meta.json")), read_json(&dir.join("progress.json")));
                json!({
                    "id": id,
                    "title": state["title"].as_str().unwrap_or(&id),
                    "source": state["source"],
                    "chapters": state["chapters"].as_array().map_or(0, Vec::len),
                    "counts": status_counts(&state),
                    "loopsClosed": loops_closed(&progress),
                    "running": running.contains(&id),
                    "addedAt": meta["addedAt"],
                    "options": meta["options"],
                    "ready": dir.join("index.html").exists(),
                    "due": reviewed_cards_due(&progress, now_ms()),
                })
            })
        })
        .collect();
    books.sort_by_key(|book| -book["addedAt"].as_i64().unwrap_or(0));
    books
}

#[tauri::command]
pub fn delete_book(app: AppHandle, jobs: tauri::State<'_, Jobs>, book_id: String) -> Result<(), String> {
    if !valid_id(&book_id) {
        return Err("bad id".into());
    }
    jobs.stop(&book_id);
    std::fs::remove_dir_all(books_root(&app).join(&book_id)).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn save_progress(app: AppHandle, book_id: String, data: Value) -> Result<(), String> {
    if !valid_id(&book_id) {
        return Err("bad id".into());
    }
    let dir = books_root(&app).join(&book_id);
    if !dir.is_dir() {
        return Err("unknown book".into());
    }
    write_json(&dir.join("progress.json"), &data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_closed_loops_and_statuses() {
        let progress = json!({ "loop": { "1": { "prime": 1, "read": 1, "recall": 1, "map": 1, "space": 1 }, "2": { "prime": 1 } } });
        assert_eq!(loops_closed(&progress), 1);
        let state = json!({ "chapters": [{ "tasks": { "quiz": { "status": "done" }, "video": { "status": "skipped" } } }] });
        let counts = status_counts(&state);
        assert_eq!((counts["done"], counts["skipped"]), (1, 1));
    }
}
