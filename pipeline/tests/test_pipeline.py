import asyncio
import json

import pytest

from neuralloop_books.engines.local import LocalEngine
from neuralloop_books.engines.notebooklm import NotebookLMEngine
from neuralloop_books.fake_client import ENUMS, FakeClient, FakeQuotaClient
from neuralloop_books.models import QuotaError
from neuralloop_books.models.fake import FakeModel
from neuralloop_books.pipeline import Options, run
from neuralloop_books.speech.fake import FakeSpeech
from neuralloop_books.state import DONE, SKIPPED, WAITING


@pytest.fixture
def options(epub, tmp_path):
    return Options(book=epub, out=tmp_path / "site", media="1", log=lambda _: None)


def run_with(opts, client):
    return asyncio.run(run(opts, NotebookLMEngine(client, ENUMS, opts)))


def run_local(opts, model=None):
    engine = LocalEngine.from_options(opts, model or FakeModel(), FakeSpeech())
    return asyncio.run(run(opts, engine))


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


def test_local_engine_makes_every_item_including_podcast_and_explainer(options):
    state = run_local(options)
    first, second = state.chapters
    assert all(entry["status"] == DONE for entry in first["tasks"].values())
    assert second["tasks"]["video"]["status"] == SKIPPED
    assert first["explainer"]["slides"] and first["transcript"].endswith(".json")
    assert state.data["engine"] == "local"
    data = book_data(options.out)
    assert data["chapters"][0]["explainer"]["slides"] and data["chapters"][0]["transcript"]


class LimitedModel(FakeModel):
    async def complete(self, kind, system, source, prompt):
        if kind == "quiz":
            raise QuotaError("429 rate limit")
        return await super().complete(kind, system, source, prompt)


def test_local_rate_limits_wait_for_the_next_run(options):
    lines = []
    options.log = lines.append
    state = run_local(options, LimitedModel())
    assert state.chapters[0]["tasks"]["quiz"]["status"] == WAITING
    assert state.chapters[0]["tasks"]["cards"]["status"] == DONE
    assert any("Pip's practice brain limit reached" in line for line in lines)
    options.retry = True
    assert run_local(options).chapters[0]["tasks"]["quiz"]["status"] == DONE


def test_widening_media_on_a_later_run_adds_only_the_new_media(options):
    run_with(options, FakeClient(delay=0))
    options.media = "1-2"
    state = run_with(options, FakeClient(delay=0))
    assert state.chapters[1]["tasks"]["audio"]["status"] == DONE


def test_auto_engine_opens_notebooklm_inside_the_running_loop(options):
    from neuralloop_books.engines.auto import AutoEngine

    async def open_fake():
        return FakeClient(delay=0)

    notebooklm = lambda: NotebookLMEngine(None, ENUMS, options, open_client=open_fake)  # noqa: E731
    local = lambda: LocalEngine.from_options(options, FakeModel(), FakeSpeech())  # noqa: E731
    state = asyncio.run(run(options, AutoEngine(notebooklm, local, options.log)))
    assert {entry["by"] for entry in state.chapters[0]["tasks"].values() if entry["status"] == DONE} == {
        "NotebookLM"
    }
