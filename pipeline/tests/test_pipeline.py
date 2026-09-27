import asyncio
import json

import pytest

from neuralloop_books.fake_client import ENUMS, FakeClient, FakeQuotaClient
from neuralloop_books.pipeline import DRY_RUN_VIDEO_NOTE, Options, run
from neuralloop_books.state import DONE, SKIPPED, WAITING


@pytest.fixture
def options(epub, tmp_path):
    return Options(book=epub, out=tmp_path / "site", media="1", log=lambda _: None)


def run_with(opts, client):
    return asyncio.run(run(opts, client, ENUMS))


def book_data(out):
    text = (out / "book-data.js").read_text()
    return json.loads(text[len("window.BOOK = ") :].rstrip(";\n"))


def test_full_run_makes_every_item_and_the_site(options):
    state = run_with(options, FakeClient(delay=0))
    first, second = state.chapters
    assert all(
        first["tasks"][t]["status"] == DONE
        for t in ("study", "graph", "quiz", "cards", "mindmap", "audio", "video")
    )
    assert second["tasks"]["video"]["status"] == SKIPPED and second["tasks"]["quiz"]["status"] == DONE
    assert first["quiz"] and first["cards"] and first["recall"] and first["graph"]["concepts"]
    data = book_data(options.out)
    assert data["chapters"][0]["read"]["kind"] == "text" and len(data["graph"]["nodes"]) == 14
    assert (options.out / "index.html").exists() and (options.out / "knowledge-graph.json").exists()


def test_rerunning_does_not_redo_finished_work(options):
    run_with(options, FakeClient(delay=0))
    client = FakeClient(delay=0)
    run_with(options, client)
    assert client.source_titles == {}  # no chapter was added again


def test_quota_limits_are_deferred_then_retried(options):
    state = run_with(options, FakeQuotaClient(delay=0))
    assert state.chapters[0]["tasks"]["audio"]["status"] == WAITING
    assert state.chapters[0]["tasks"]["quiz"]["status"] == DONE
    options.retry = True
    state = run_with(options, FakeClient(delay=0))
    assert state.chapters[0]["tasks"]["audio"]["status"] == DONE


def test_dry_runs_explain_the_missing_video(options):
    options.dry_run = True
    state = run_with(options, FakeClient(delay=0))
    video = state.chapters[0]["tasks"]["video"]
    assert video["status"] == SKIPPED and video["error"] == DRY_RUN_VIDEO_NOTE


def test_widening_media_on_a_later_run_adds_only_the_new_media(options):
    run_with(options, FakeClient(delay=0))
    options.media = "1-2"
    state = run_with(options, FakeClient(delay=0))
    assert state.chapters[1]["tasks"]["audio"]["status"] == DONE
