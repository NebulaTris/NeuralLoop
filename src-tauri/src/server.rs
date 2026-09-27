//! The private `nlbook://` scheme that serves each book's study site from the library folder.
//! Supports byte ranges, which macOS needs to play and seek video.

use crate::storage::books_root;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use tauri::http::{Request, Response};
use tauri::AppHandle;

const MAX_OPEN_RANGE: u64 = 4 * 1024 * 1024;

pub fn mime_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase().as_str() {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "pdf" => "application/pdf",
        "mp4" => "video/mp4",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "md" => "text/markdown; charset=utf-8",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(value) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(value);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Parse `bytes=start-end` into an inclusive range. Open-ended ranges are served in 4 MB chunks.
pub fn parse_range(header: &str, len: u64) -> Option<(u64, u64)> {
    let (first, last) = header.strip_prefix("bytes=")?.split_once('-')?;
    if len == 0 {
        return None;
    }
    let (start, end) = if first.is_empty() {
        let suffix: u64 = last.parse().ok()?;
        (len.saturating_sub(suffix), len - 1)
    } else {
        let start: u64 = first.parse().ok()?;
        let end = if last.is_empty() { (start + MAX_OPEN_RANGE - 1).min(len - 1) } else { last.parse::<u64>().ok()?.min(len - 1) };
        (start, end)
    };
    (start <= end && start < len).then_some((start, end))
}

fn plain(status: u16, message: &str) -> Response<Vec<u8>> {
    Response::builder().status(status).header("Content-Type", "text/plain").body(message.as_bytes().to_vec()).unwrap_or_default()
}

pub fn serve(app: &AppHandle, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    let Ok(root) = books_root(app).canonicalize() else { return plain(500, "library unavailable") };
    let relative = percent_decode(request.uri().path().trim_start_matches('/'));
    if relative.split('/').any(|segment| segment == "..") {
        return plain(403, "forbidden");
    }
    let path = match root.join(&relative).canonicalize() {
        Ok(path) if path.starts_with(&root) && path.is_file() => path,
        _ => return plain(404, "not found"),
    };
    let Ok(mut file) = fs::File::open(&path) else { return plain(404, "not found") };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let range = request.headers().get("range").and_then(|v| v.to_str().ok()).and_then(|h| parse_range(h, len));
    let response =
        Response::builder().header("Content-Type", mime_type(&path)).header("Accept-Ranges", "bytes").header("Cache-Control", "no-cache");
    match range {
        Some((start, end)) => {
            let mut body = vec![0u8; (end - start + 1) as usize];
            if file.seek(SeekFrom::Start(start)).and_then(|_| file.read_exact(&mut body)).is_err() {
                return plain(416, "range not satisfiable");
            }
            response
                .status(206)
                .header("Content-Range", format!("bytes {start}-{end}/{len}"))
                .header("Content-Length", body.len().to_string())
                .body(body)
        }
        None => {
            let mut body = Vec::new();
            let _ = file.read_to_end(&mut body);
            response.status(200).header("Content-Length", body.len().to_string()).body(body)
        }
    }
    .unwrap_or_else(|_| plain(500, "response error"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_ranges() {
        assert_eq!(parse_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_range("bytes=900-", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=0-", 10_000_000), Some((0, MAX_OPEN_RANGE - 1)));
        assert_eq!(parse_range("bytes=2000-", 1000), None);
        assert_eq!(parse_range("items=0-1", 1000), None);
    }

    #[test]
    fn decoding_and_types() {
        assert_eq!(percent_decode("my%20book/index.html"), "my book/index.html");
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(mime_type(Path::new("a/VIDEO.MP4")), "video/mp4");
    }
}
