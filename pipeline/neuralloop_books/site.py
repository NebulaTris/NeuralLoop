"""Write a book's data (book.json for the app, book-data.js for the site) plus the site's static files."""

import json
import shutil
import time
from pathlib import Path

from . import book_graph
from .config import TASKS
from .state import BookState

SITE_DIR = Path(__file__).resolve().parent.parent / "site"
SITE_FILES = ("index.html", "styles.css", "app.js", "pip-poses.js")
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


def build(out_dir: Path, state: BookState, options: dict) -> None:
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
    payload = json.dumps(data, ensure_ascii=False)
    (out_dir / "book-data.js").write_text("window.BOOK = " + payload + ";\n", encoding="utf-8")
    # The native app reads book.json; written atomically so it never sees half a file.
    tmp = out_dir / "book.json.tmp"
    tmp.write_text(payload, encoding="utf-8")
    tmp.replace(out_dir / "book.json")
    (out_dir / "knowledge-graph.json").write_text(
        json.dumps(data["graph"], indent=1, ensure_ascii=False), encoding="utf-8"
    )
    for name in SITE_FILES:
        if (SITE_DIR / name).exists():
            shutil.copyfile(SITE_DIR / name, out_dir / name)


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
