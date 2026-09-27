//! Where things live on disk, and small JSON helpers.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

pub fn books_root(app: &AppHandle) -> PathBuf {
    let dir = app.path().app_data_dir().unwrap_or_else(|_| PathBuf::from(".")).join("books");
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn config_file(app: &AppHandle, name: &str) -> PathBuf {
    let dir = app.path().app_config_dir().unwrap_or_else(|_| PathBuf::from("."));
    let _ = fs::create_dir_all(&dir);
    dir.join(name)
}

/// The file's JSON, or `Null` if it's missing or unreadable.
pub fn read_json(path: &Path) -> Value {
    fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

/// Write atomically: a crash never leaves a half-written file.
pub fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, value.to_string()).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Book ids are folder names we create: lowercase letters, digits, and dashes only.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 80 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub fn slug(text: &str) -> String {
    let mut out = String::new();
    for c in text.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c)
        } else if !out.ends_with('-') {
            out.push('-')
        }
    }
    let trimmed: String = out.trim_matches('-').chars().take(60).collect();
    if trimmed.is_empty() {
        "book".into()
    } else {
        trimmed
    }
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_safe_folder_names() {
        assert_eq!(slug("Designing Data-Intensive Apps!"), "designing-data-intensive-apps");
        assert_eq!(slug("!!!"), "book");
    }

    #[test]
    fn ids_reject_path_tricks() {
        assert!(valid_id("a-b-1"));
        assert!(!valid_id("../x") && !valid_id("") && !valid_id("a/b"));
    }
}
