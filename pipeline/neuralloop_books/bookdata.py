"""Write a book's data for the app: book.json (everything the app shows) and knowledge-graph.json
(the book map in Understand-Anything's format). Both are written atomically, so the app never reads half
a file.

book.json is rewritten twice per item, and EPUB chapters carry their whole text, so each chapter's JSON is
kept and only made again when that chapter changes (its items' statuses, or its file). Writes happen off
the event loop, one at a time.
"""

import asyncio
import json
import os
import threading
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
_HEAD = {"dryRun": False, "engine": "notebooklm", "provider": "", "model": ""}  # with their defaults
_lock = threading.Lock()  # two writes never interleave (the files, and the cache below)
# chapter file -> (what the chapter's JSON was made from, the JSON). A chapter's results only change
# together with its items' statuses, so those (and the file's size and time) are the key.
_chapters: dict[Path, tuple[tuple, str]] = {}


def write(out_dir: Path, state: BookState, options: dict) -> None:
    with _lock:
        _write_now(out_dir, _snapshot(state), options)


async def write_async(out_dir: Path, state: BookState, options: dict) -> None:
    """write(), in a worker thread. The state is copied first, so items finishing meanwhile can't change
    it halfway through."""
    snapshot = _snapshot(state)

    def locked() -> None:
        with _lock:
            _write_now(out_dir, snapshot, options)

    await asyncio.to_thread(locked)


def _snapshot(state: BookState) -> dict:
    """What book.json needs from the state, safe to read from another thread: each chapter's results are
    replaced (never changed in place) when an item finishes, so copying the dictionaries is enough."""
    return {
        "title": state.data["title"],
        "source": state.data["source"],
        **{key: state.data.get(key, default) for key, default in _HEAD.items()},
        "chapters": [
            {**c, "tasks": {t: dict(entry) for t, entry in c["tasks"].items()}} for c in state.chapters
        ],
    }


def _write_now(out_dir: Path, snapshot: dict, options: dict) -> None:
    head = {
        "title": snapshot["title"],
        "source": snapshot["source"],
        "made": time.strftime("%Y-%m-%d %H:%M"),
        **{key: snapshot[key] for key in _HEAD},
        "options": options,
    }
    graph = book_graph.build(snapshot["chapters"])
    chapters = ", ".join(_cached_chapter_json(out_dir, c) for c in snapshot["chapters"])
    # Exactly what json.dumps of the whole book gives, built from the kept pieces.
    text = (
        json.dumps(head, ensure_ascii=False)[:-1]
        + f', "chapters": [{chapters}], "graph": '
        + json.dumps(graph, ensure_ascii=False)
        + "}"
    )
    _write_atomic(out_dir / "book.json", text)
    _write_atomic(out_dir / "knowledge-graph.json", json.dumps(graph, indent=1, ensure_ascii=False))


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _cached_chapter_json(out_dir: Path, chapter: dict) -> str:
    file = out_dir / "chapters" / chapter["file"]
    try:
        stat = os.stat(file)
        seen = (stat.st_mtime_ns, stat.st_size)
    except OSError:
        seen = None
    key = (json.dumps(chapter["tasks"], sort_keys=True, ensure_ascii=False), seen)
    cached = _chapters.get(file)
    if cached and cached[0] == key:
        return cached[1]
    text = _chapter_json(out_dir, chapter)
    _chapters[file] = (key, text)
    return text


def _chapter_json(out_dir: Path, chapter: dict) -> str:
    return json.dumps(_chapter_payload(out_dir, chapter), ensure_ascii=False)


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
    return {"kind": "text", "text": file.read_text(encoding="utf-8")[:MAX_TEXT]}
