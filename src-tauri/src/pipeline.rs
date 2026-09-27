//! Running the book pipeline (pipeline/nl_book.py) with the user's Python, streaming its progress.

use crate::settings::{self, find_python};
use crate::storage::{books_root, now_ms, read_json, slug, valid_id, write_json};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const STDERR_LINES_KEPT: usize = 30;

/// Running pipelines, by book id.
#[derive(Default)]
pub struct Jobs(pub Mutex<HashMap<String, Child>>);

impl Jobs {
    pub fn running_ids(&self) -> Vec<String> {
        self.0.lock().map(|jobs| jobs.keys().cloned().collect()).unwrap_or_default()
    }

    pub fn stop(&self, id: &str) {
        if let Ok(mut jobs) = self.0.lock() {
            if let Some(mut child) = jobs.remove(id) {
                let _ = child.kill();
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PipelineOptions {
    path: Option<String>,
    book_id: Option<String>,
    media: String,
    style: String,
    audio: String,
    video: String,
    language: String,
    dry_run: bool,
    retry: bool,
}

fn bundled(app: &AppHandle, relative: &str) -> Option<PathBuf> {
    let mut candidates = vec![];
    if let Ok(resources) = app.path().resource_dir() {
        candidates.push(resources.join("pipeline").join(relative));
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("../pipeline").join(relative));
        candidates.push(cwd.join("pipeline").join(relative));
    }
    candidates.into_iter().find(|p| p.is_file())
}

pub fn sample_book(app: &AppHandle) -> Option<String> {
    bundled(app, "sample/sample-book.epub").map(|p| p.to_string_lossy().into_owned())
}

/// Book id and file for this run: a new id for a new file, or the saved file for an existing book.
fn resolve_book(root: &Path, options: &PipelineOptions) -> Result<(String, String), String> {
    if let Some(id) = options.book_id.as_deref().filter(|id| valid_id(id)) {
        let path = read_json(&root.join(id).join("meta.json"))["path"]
            .as_str()
            .map(String::from)
            .ok_or("setup: this book's original file is unknown")?;
        return Ok((id.to_string(), path));
    }
    let path = options.path.clone().ok_or("setup: no book given")?;
    let base = slug(Path::new(&path).file_stem().and_then(|s| s.to_str()).unwrap_or("book"));
    let mut id = base.clone();
    let mut n = 2;
    while root.join(&id).exists() && read_json(&root.join(&id).join("meta.json"))["path"].as_str() != Some(path.as_str()) {
        id = format!("{base}-{n}");
        n += 1;
    }
    Ok((id, path))
}

#[tauri::command]
pub fn start_pipeline(app: AppHandle, jobs: tauri::State<'_, Jobs>, opts: PipelineOptions) -> Result<String, String> {
    let root = books_root(&app);
    let (id, book_path) = resolve_book(&root, &opts)?;
    if jobs.running_ids().contains(&id) {
        return Err("setup: this book is already being prepared".into());
    }
    if !Path::new(&book_path).is_file() {
        return Err(format!("setup: can't find the book file at {book_path}"));
    }
    let out = root.join(&id);
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    remember_book(&out, &book_path, &opts)?;

    let python = find_python(&settings::load(&app)).ok_or("setup: Python 3.10+ wasn't found. Set it in Settings.")?;
    let script = bundled(&app, "nl_book.py").ok_or("setup: the pipeline script is missing from the app")?;
    let mut command = Command::new(python);
    command
        .arg(&script)
        .arg(&book_path)
        .arg("--out")
        .arg(&out)
        .arg("--no-open")
        .args(["--media", &opts.media, "--style", &opts.style, "--audio", &opts.audio])
        .args(["--video", &opts.video, "--language", &opts.language])
        .env("PYTHONUNBUFFERED", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if opts.dry_run {
        command.arg("--dry-run");
    }
    if opts.retry {
        command.arg("--retry");
    }
    let mut child = command.spawn().map_err(|e| format!("setup: couldn't start Python ({e})"))?;
    let stdout = child.stdout.take().ok_or("setup: no output")?;
    let stderr = child.stderr.take().ok_or("setup: no output")?;
    jobs.0.lock().map_err(|e| e.to_string())?.insert(id.clone(), child);
    stream_progress(app, id.clone(), stdout, stderr);
    Ok(id)
}

fn remember_book(out: &Path, book_path: &str, opts: &PipelineOptions) -> Result<(), String> {
    let meta_path = out.join("meta.json");
    let mut meta = read_json(&meta_path);
    if meta.is_null() {
        meta = json!({ "addedAt": now_ms() });
    }
    meta["path"] = json!(book_path);
    meta["options"] = json!({
        "media": opts.media, "style": opts.style, "audio": opts.audio,
        "video": opts.video, "language": opts.language, "dryRun": opts.dry_run,
    });
    write_json(&meta_path, &meta)
}

/// Forward each output line to the UI as a `pipeline` event, then report how the run ended.
fn stream_progress(app: AppHandle, id: String, stdout: impl std::io::Read + Send + 'static, stderr: impl std::io::Read + Send + 'static) {
    std::thread::spawn(move || {
        let recent_errors: Arc<Mutex<Vec<String>>> = Arc::default();
        let errors = recent_errors.clone();
        let error_reader = std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Ok(mut kept) = errors.lock() {
                    kept.push(line);
                    if kept.len() > STDERR_LINES_KEPT {
                        kept.remove(0);
                    }
                }
            }
        });
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = app.emit("pipeline", json!({ "bookId": id, "line": line }));
        }
        let _ = error_reader.join();
        let child = app.state::<Jobs>().0.lock().ok().and_then(|mut jobs| jobs.remove(&id));
        let code = child.and_then(|mut c| c.wait().ok()).and_then(|status| status.code()).unwrap_or(-1);
        let stderr_text = recent_errors.lock().map(|kept| kept.join("\n")).unwrap_or_default();
        let _ = app.emit("pipeline", json!({ "bookId": id, "done": true, "code": code, "stderr": stderr_text }));
        if code == 0 {
            let title = read_json(&books_root(&app).join(&id).join("state.json"))["title"].as_str().unwrap_or("Your book").to_string();
            let _ = app
                .notification()
                .builder()
                .title(format!("📚 “{title}” is ready"))
                .body("Pip finished preparing your chapters. Come take a look!")
                .show();
        }
    });
}

#[tauri::command]
pub fn cancel_pipeline(jobs: tauri::State<'_, Jobs>, book_id: String) {
    jobs.stop(&book_id);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(path: Option<&str>, book_id: Option<&str>) -> PipelineOptions {
        PipelineOptions {
            path: path.map(String::from),
            book_id: book_id.map(String::from),
            media: "1-2".into(),
            style: "kawaii".into(),
            audio: "deep-dive".into(),
            video: "explainer".into(),
            language: "en".into(),
            dry_run: true,
            retry: false,
        }
    }

    #[test]
    fn new_books_get_a_slug_id_and_same_named_books_get_a_suffix() {
        let root = std::env::temp_dir().join(format!("nlb-test-{}", now_ms()));
        std::fs::create_dir_all(root.join("clean-code")).unwrap();
        write_json(&root.join("clean-code/meta.json"), &json!({ "path": "/a/Clean Code.pdf" })).unwrap();
        assert_eq!(resolve_book(&root, &options(Some("/a/Clean Code.pdf"), None)).unwrap().0, "clean-code");
        assert_eq!(resolve_book(&root, &options(Some("/b/Clean Code.pdf"), None)).unwrap().0, "clean-code-2");
        assert_eq!(resolve_book(&root, &options(None, Some("clean-code"))).unwrap().1, "/a/Clean Code.pdf");
        let _ = std::fs::remove_dir_all(root);
    }
}
