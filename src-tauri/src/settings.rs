//! User settings (settings.json) and the Python environment check.

use crate::storage::{config_file, read_json, write_json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;
use tauri::AppHandle;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Empty means "find Python automatically".
    pub python: String,
    pub nudges: bool,
    pub quiet_start: u32,
    pub quiet_end: u32,
    /// Unix ms; nudges are paused until then.
    pub paused_until: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { python: String::new(), nudges: true, quiet_start: 22, quiet_end: 8, paused_until: 0 }
    }
}

pub fn load(app: &AppHandle) -> Settings {
    serde_json::from_value(read_json(&config_file(app, "settings.json"))).unwrap_or_default()
}

pub fn save(app: &AppHandle, settings: &Settings) -> Result<(), String> {
    write_json(&config_file(app, "settings.json"), &serde_json::to_value(settings).map_err(|e| e.to_string())?)
}

#[tauri::command]
pub fn get_settings(app: AppHandle) -> Settings {
    load(&app)
}

#[tauri::command]
pub fn set_settings(app: AppHandle, settings: Settings) -> Result<(), String> {
    save(&app, &settings)
}

fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_default())
}

fn is_python_310_plus(python: &str) -> bool {
    Command::new(python)
        .args(["-c", "import sys; print(sys.version_info >= (3, 10))"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "True")
        .unwrap_or(false)
}

/// The configured Python, or the first suitable one: the POC virtualenv, then python3.x on PATH.
pub fn find_python(settings: &Settings) -> Option<String> {
    let configured = settings.python.trim();
    if !configured.is_empty() {
        return is_python_310_plus(configured).then(|| configured.to_string());
    }
    let home = home_dir();
    let mut candidates = vec![
        home.join("neuralloop-poc/.venv/bin/python").to_string_lossy().into_owned(),
        home.join("neuralloop/.venv/bin/python").to_string_lossy().into_owned(),
        home.join("neuralloop-poc\\.venv\\Scripts\\python.exe").to_string_lossy().into_owned(),
    ];
    candidates.extend(["python3.13", "python3.12", "python3.11", "python3.10", "python3", "python"].map(String::from));
    candidates.into_iter().find(|p| is_python_310_plus(p))
}

const LIBRARY_PROBE: &str = "import json, importlib.metadata as m\nr = {}\nfor k in ('notebooklm-py', 'pypdf'):\n    try: r[k] = m.version(k)\n    except Exception: r[k] = None\nprint(json.dumps(r))";

/// What's installed, for the setup checklist in the app.
#[tauri::command]
pub async fn check_setup(app: AppHandle) -> Value {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(python) = find_python(&load(&app)) else { return json!({ "python": null }) };
        let libraries: Value = Command::new(&python)
            .args(["-c", LIBRARY_PROBE])
            .output()
            .ok()
            .and_then(|o| serde_json::from_slice(&o.stdout).ok())
            .unwrap_or(json!({}));
        let home = home_dir();
        let signed_in =
            [".notebooklm/profiles/default/storage_state.json", ".notebooklm/storage_state.json"].iter().any(|p| home.join(p).exists());
        json!({
            "python": python,
            "notebooklm": libraries["notebooklm-py"],
            "pypdf": libraries["pypdf"],
            "signedIn": signed_in,
            "samplePath": crate::pipeline::sample_book(&app),
        })
    })
    .await
    .unwrap_or(json!({ "python": null }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let partial: Settings = serde_json::from_value(json!({ "quietStart": 21 })).unwrap();
        assert_eq!(partial, Settings { quiet_start: 21, ..Settings::default() });
    }
}
