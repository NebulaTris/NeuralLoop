import asyncio
import json
from pathlib import Path

import pytest

from neuralloop_books.engines.local import LocalEngine
from neuralloop_books.engines.notebooklm import NotebookLMEngine
from neuralloop_books.fake_client import ENUMS, FakeClient, FakeQuotaClient, FakeStaleSessionClient
from neuralloop_books.models import QuotaError, SetupError
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
    return json.loads((out / "book.json").read_text())


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
    assert (options.out / "knowledge-graph.json").exists() and not (options.out / "index.html").exists()


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


class TimingEngine:
    """Records when each item starts; media items take longer."""

    name = "Timer"

    def __init__(self):
        self.started = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def prepare(self, state):
        pass

    async def make(self, task, chapter):
        self.started.append((chapter["n"], task))
        await asyncio.sleep(1.0 if task in ("audio", "video") else 0)
        return {}


def test_slow_media_have_their_own_lane_so_text_items_keep_flowing(options):
    options.parallel, options.media = 1, "1-2"
    engine = TimingEngine()
    asyncio.run(run(options, engine))
    started = engine.started
    # Chapter 2's text items start while chapter 1's podcast is still being made.
    assert started.index((2, "study")) < started.index((1, "video"))
    assert started[:2] == [(1, "study"), (1, "audio")]  # the slow podcast starts right away, in its own lane
    text = [item for item in started if item[1] not in ("audio", "video")]
    assert text[:6] == [(1, "study"), (1, "graph"), (1, "quiz"), (1, "cards"), (1, "mindmap"), (2, "study")]


def test_every_engine_builds_the_book_map(options):
    run_local(options)
    data = book_data(options.out)
    graph = data["graph"]
    assert graph["nodes"] and graph["edges"] and graph["tour"]
    assert all(chapter["graph"]["concepts"] for chapter in data["chapters"])


FIXTURE = Path(__file__).parent / "fixtures" / "book.json"


def test_the_book_map_file_matches_book_json_and_no_half_written_files_are_left(options):
    run_local(options)
    graph = json.loads((options.out / "knowledge-graph.json").read_text())
    assert graph == book_data(options.out)["graph"] and graph["nodes"]
    assert not list(options.out.glob("*.tmp")) and not (options.out / "book-data.js").exists()


def test_the_shared_fixture_still_has_every_field_the_pipeline_writes(options):
    """apple/Tests decode this fixture; when the pipeline's shape changes, regenerate it (fixtures/README)."""
    run_local(options)
    made, fixture = book_data(options.out), json.loads(FIXTURE.read_text())
    assert set(made) == set(fixture)
    assert set(made["chapters"][0]) == set(fixture["chapters"][0])
    assert set(made["graph"]) == set(fixture["graph"])


def test_a_crashed_run_is_resumed_and_its_working_items_finished(options):
    run_local(options)
    state = json.loads((options.out / "state.json").read_text())
    state["chapters"][0]["tasks"]["quiz"]["status"] = "working"
    (options.out / "state.json").write_text(json.dumps(state))
    assert run_local(options).chapters[0]["tasks"]["quiz"]["status"] == DONE


def test_two_runs_never_prepare_the_same_book_at_once(options):
    import fcntl
    import os

    options.out.mkdir(parents=True)
    with open(options.out / ".running", "w") as held:  # another run holds the book's lock
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        held.write(str(os.getpid()))
        held.flush()
        with pytest.raises(ValueError, match="already being prepared"):
            run_local(options)


def test_a_second_run_started_during_the_first_stops(options):
    from neuralloop_books.pipeline import _book_lock

    options.out.mkdir(parents=True)
    with _book_lock(options.out):
        assert (options.out / ".running").read_text().strip() == str(__import__("os").getpid())
        with pytest.raises(ValueError, match="already being prepared"), _book_lock(options.out):
            pass
    with _book_lock(options.out):  # released: the next run gets it
        pass
    assert not (options.out / ".running").exists()


def test_a_left_over_lock_file_whose_process_id_was_reused_does_not_block(options):
    """After a crash (even SIGKILL) nothing holds the lock, whatever process now has that id."""
    import os

    options.out.mkdir(parents=True)
    (options.out / ".running").write_text(str(os.getpid()))  # a live process, but it holds no lock
    assert run_local(options).chapters[0]["tasks"]["quiz"]["status"] == DONE


class SetupFailsWhileMediaRuns:
    """One item needs setup fixed while a slow podcast is still being made."""

    name = "Timer"

    def __init__(self):
        self.running = 0
        self.running_at_exit = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        self.running_at_exit = self.running
        return False

    async def prepare(self, state):
        pass

    async def make(self, task, chapter):
        self.running += 1
        try:
            if task == "study":
                await asyncio.sleep(0.05)
                raise SetupError("the key was revoked")
            await asyncio.sleep(5 if task in ("audio", "video") else 0)
            return {}
        finally:
            self.running -= 1


def test_a_setup_error_cancels_the_other_items_before_the_engine_closes(options):
    engine = SetupFailsWhileMediaRuns()
    with pytest.raises(SetupError):
        asyncio.run(run(options, engine))
    assert engine.running_at_exit == 0


class Failing:
    def __init__(self, name, error=None):
        self.name, self.error = name, error

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def prepare(self, state):
        pass

    async def make(self, task, chapter):
        if self.error and task == "quiz":
            raise self.error
        return {}


def test_a_limit_on_the_local_fallback_is_logged_with_the_fallbacks_name(options):
    from neuralloop_books.engines.auto import AutoEngine

    lines = []
    options.log = lines.append
    engine = AutoEngine(
        lambda: Failing("NotebookLM", RuntimeError("boom")),
        lambda: Failing("Ollama", QuotaError("slow down")),
        options.log,
    )
    state = asyncio.run(run(options, engine))
    quiz = state.chapters[0]["tasks"]["quiz"]
    assert quiz["status"] == WAITING and quiz["error"].startswith("Ollama")
    assert any("quiz: Ollama limit reached" in line for line in lines)
    assert not any("NotebookLM limit reached" in line for line in lines)


def test_a_stale_lock_from_a_dead_run_does_not_block(options):
    options.out.mkdir(parents=True)
    (options.out / ".running").write_text("999999")  # no such process
    assert run_local(options).chapters[0]["tasks"]["quiz"]["status"] == DONE
    assert not (options.out / ".running").exists()


class OpenedLikeTheRealLibrary:
    """notebooklm-py's from_storage() gives a context whose __aenter__ returns the real client."""

    def __init__(self):
        self.client = FakeClient(delay=0)
        self.closed = False

    async def __aenter__(self):
        return self.client

    async def __aexit__(self, *exc):
        self.closed = True
        return False


def test_notebooklm_uses_the_client_its_context_opens(options):
    context = OpenedLikeTheRealLibrary()
    state = asyncio.run(run(options, NotebookLMEngine(context, ENUMS, options)))
    assert state.chapters[0]["tasks"]["quiz"]["status"] == DONE and context.closed


def test_notebooklm_media_replaces_what_an_earlier_engine_left(options):
    """NotebookLM media has no transcript or slides: drop old ones so they never mismatch."""
    run_local(options)
    path = options.out / "state.json"
    saved = json.loads(path.read_text())
    for task in ("audio", "video"):
        saved["chapters"][0]["tasks"][task]["status"] = "todo"
    path.write_text(json.dumps(saved))
    run_with(options, FakeClient(delay=0))
    first = book_data(options.out)["chapters"][0]
    assert first["audio"] and first["video"]
    assert first.get("transcript") is None and first.get("explainer") is None


def test_a_stale_notebooklm_session_is_refreshed_and_the_item_made_by_notebooklm(options):
    client = FakeStaleSessionClient(delay=0)
    state = run_with(options, client)
    first = state.chapters[0]["tasks"]
    assert first["audio"]["status"] == DONE and first["video"]["status"] == DONE
    assert client.refreshes >= 1


def test_a_failed_item_never_saves_or_prints_an_api_key(options, monkeypatch):
    """SDK and command-line errors can quote the request; state.json and book.json sync to Drive."""
    key = "sk-ant-api03-" + "k" * 40
    monkeypatch.setenv("ANTHROPIC_API_KEY", key)
    lines = []
    options.log = lines.append
    error = RuntimeError(f"401 for key {key}\nStudy site: /somewhere/else")
    state = asyncio.run(run(options, Failing("Claude", error)))
    quiz = state.chapters[0]["tasks"]["quiz"]
    assert quiz["status"] == "failed" and "[key hidden]" in quiz["error"] and "\n" not in quiz["error"]
    saved = (options.out / "state.json").read_text() + (options.out / "book.json").read_text()
    assert key not in saved and not any(key in line for line in lines)
    assert not any(line.startswith("Study site:") for printed in lines for line in printed.splitlines())


class FailsFirstChapter(Failing):
    async def make(self, task, chapter):
        if self.error and task == "quiz" and chapter["n"] == 1:
            raise self.error
        return {}


def test_a_limit_on_the_fallback_does_not_stop_notebooklm_making_later_items(options):
    from neuralloop_books.engines.auto import AutoEngine

    options.parallel = 1
    engine = AutoEngine(
        lambda: FailsFirstChapter("NotebookLM", RuntimeError("boom")),
        lambda: Failing("Ollama", QuotaError("slow down")),
        options.log,
    )
    state = asyncio.run(run(options, engine))
    first, second = (c["tasks"]["quiz"] for c in state.chapters)
    assert first["status"] == WAITING and first["error"].startswith("Ollama")
    assert second["status"] == DONE and second["by"] == "NotebookLM"


def test_a_limit_on_the_engine_itself_still_stops_later_items_of_that_kind(options):
    options.parallel = 1
    options.media = "none"
    state = run_local(options, LimitedModel())
    assert [c["tasks"]["quiz"]["status"] for c in state.chapters] == [WAITING, WAITING]


def test_a_run_reports_its_progress_and_remembers_how_long_items_took(options):
    state = run_local(options)
    feed = json.loads((options.out / "activity.json").read_text())
    assert feed["ended"] is True and feed["items"] == [] and feed["queue"] == []
    made = {key.split(":")[-1] for key, seconds in state.data["timings"].items() if seconds}
    assert {"study", "quiz", "cards", "audio", "video"} <= made  # "<maker>:<item>" → recent durations
