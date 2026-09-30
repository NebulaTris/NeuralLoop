import asyncio
import json

import pytest

from neuralloop_books import bookdata
from neuralloop_books.state import BookState
from neuralloop_books.testing import LONG


@pytest.fixture
def book(tmp_path):
    (tmp_path / "chapters").mkdir()
    chapters = []
    for n in (1, 2):
        (tmp_path / "chapters" / f"{n:02d}.md").write_text(f"# Chapter {n}\n\n{LONG}")
        chapters.append({"n": n, "title": f"Chapter {n}", "file": f"{n:02d}.md"})
    state = BookState.create(
        tmp_path / "state.json", title="T", source="b.epub", chapters=chapters, dry_run=True
    )
    return tmp_path, state


def reference(out, state, options):
    """book.json as it was always written: one json.dumps of the whole book."""
    data = json.loads((out / "book.json").read_text())
    expected = {
        **{k: data[k] for k in ("title", "source", "made", "dryRun", "engine", "provider", "model")},
        "options": options,
        "chapters": [
            {
                **{f: c.get(f) for f in bookdata.CHAPTER_FIELDS},
                "read": {"kind": "text", "text": (out / "chapters" / c["file"]).read_text()},
                "status": {t: c["tasks"][t]["status"] for t in bookdata.TASKS},
                "notes": {t: c["tasks"][t].get("error", "") for t in bookdata.TASKS},
            }
            for c in state.chapters
        ],
        "graph": data["graph"],
    }
    return json.dumps(expected, ensure_ascii=False)


def test_book_json_is_unchanged_by_caching(book):
    out, state = book
    options = {"audio": "brief"}
    bookdata.write(out, state, options)
    assert (out / "book.json").read_text() == reference(out, state, options)
    state.chapters[0]["quiz"] = [{"q": "Why?", "options": ["a", "b"], "a": 0, "hint": "", "why": ["", ""]}]
    state.chapters[0]["tasks"]["quiz"].update(status="done", error="")
    bookdata.write(out, state, options)
    assert (out / "book.json").read_text() == reference(out, state, options)
    assert json.loads((out / "book.json").read_text())["chapters"][0]["status"]["quiz"] == "done"


def test_only_changed_chapters_are_serialised_again(book, monkeypatch):
    out, state = book
    bookdata.write(out, state, {})
    calls = []
    real = bookdata._chapter_json
    monkeypatch.setattr(bookdata, "_chapter_json", lambda o, c: calls.append(c["n"]) or real(o, c))
    bookdata.write(out, state, {})
    assert calls == []
    state.chapters[1]["tasks"]["cards"]["status"] = "working"
    bookdata.write(out, state, {})
    assert calls == [2]


def test_writes_run_off_the_event_loop_one_at_a_time(book, monkeypatch):
    import threading

    out, state = book
    active, most, threads = [0], [0], set()
    real = bookdata._write_now

    def watched(*args):
        threads.add(threading.get_ident())
        active[0] += 1
        most[0] = max(most[0], active[0])
        try:
            real(*args)
        finally:
            active[0] -= 1

    monkeypatch.setattr(bookdata, "_write_now", watched)

    async def go():
        await asyncio.gather(*(bookdata.write_async(out, state, {}) for _ in range(6)))

    asyncio.run(go())
    assert most[0] == 1 and threading.get_ident() not in threads
    json.loads((out / "book.json").read_text())
    assert not list(out.glob("*.tmp"))
