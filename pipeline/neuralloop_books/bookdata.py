"""Write a book's data for the app: book.json (everything the app shows) and knowledge-graph.json
(the book map in Understand-Anything's format). Both are written atomically, so the app never reads half
a file."""

import json
import os
import time
from pathlib import Path

from . import book_graph
from .config import TASKS
from .state import BookState

MAX_TEXT = 400_000
CHAPTER_FIELDS = (
    "n",
    "title",
    "pages",
    "graph",
    "quiz",
    "cards",
    "mindmap",
    "audio",
    "video",
    "guide",
    "recall",
    "explainer",
    "transcript",
)
# Chapter text never changes after splitting; keep it instead of re-reading every chapter after every item.
_texts: dict[Path, tuple[int, int, str]] = {}


def write(out_dir: Path, state: BookState, options: dict) -> None:
    data = {
        "title": state.data["title"],
        "source": state.data["source"],
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "dryRun": state.data.get("dryRun", False),
        "engine": state.data.get("engine", "notebooklm"),
        "provider": state.data.get("provider", ""),
        "model": state.data.get("model", ""),
        "options": options,
        "chapters": [_chapter_payload(out_dir, c) for c in state.chapters],
        "graph": book_graph.build(state.chapters),
    }
    _write_atomic(out_dir / "book.json", json.dumps(data, ensure_ascii=False))
    _write_atomic(out_dir / "knowledge-graph.json", json.dumps(data["graph"], indent=1, ensure_ascii=False))


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _chapter_payload(out_dir: Path, chapter: dict) -> dict:
    payload = {field: chapter.get(field) for field in CHAPTER_FIELDS}
    payload["read"] = _reading(out_dir / "chapters" / chapter["file"])
    payload["status"] = {t: chapter["tasks"][t]["status"] for t in TASKS}
    payload["notes"] = {t: chapter["tasks"][t].get("error", "") for t in TASKS}
    return payload


def _reading(file: Path) -> dict | None:
    if not file.exists():
        return None
    if file.suffix == ".pdf":
        return {"kind": "pdf", "file": f"chapters/{file.name}"}
    return {"kind": "text", "text": _text(file)}


def _text(file: Path) -> str:
    stat = os.stat(file)
    cached = _texts.get(file)
    if cached and cached[:2] == (stat.st_mtime_ns, stat.st_size):
        return cached[2]
    text = file.read_text(encoding="utf-8")[:MAX_TEXT]
    _texts[file] = (stat.st_mtime_ns, stat.st_size, text)
    return text
