"""The NotebookLM engine: never spending NotebookLM's allowance twice on one item, reading how a request
ended, adding chapters patiently, and finding its way back when the notebook or a source is gone."""

import asyncio
import json
from datetime import datetime
from types import SimpleNamespace

import pytest

from neuralloop_books import config
from neuralloop_books.engines.auto import AutoEngine
from neuralloop_books.engines.notebooklm import NotebookLMEngine
from neuralloop_books.fake_client import (
    ENUMS,
    FakeClient,
    FakeDownloadFailsClient,
    FakeLostReplyClient,
    FakeQuotaClient,
    FakeSlowSourceClient,
    FakeStaleTwiceWhileWaitingClient,
    RPCTimeoutError,
    SourceTimeoutError,
    WaitTimeoutError,
)
from neuralloop_books.pipeline import Options, run
from neuralloop_books.state import DONE, FAILED, WAITING


@pytest.fixture
def options(epub, tmp_path):
    return Options(book=epub, out=tmp_path / "site", media="1", log=lambda _: None)


@pytest.fixture(autouse=True)
def no_retry_pause(monkeypatch):
    monkeypatch.setattr(config, "NOTEBOOKLM_RETRY_DELAYS", (0, 0, 0))


def run_with(opts, client):
    return asyncio.run(run(opts, NotebookLMEngine(client, ENUMS, opts)))


class LocalStandIn:
    """auto's fallback: makes whatever it's handed, and remembers what that was."""

    name = "Ollama"

    def __init__(self):
        self.made: list[tuple[int, str]] = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def prepare(self, state):
        pass

    async def make(self, task, chapter):
        self.made.append((chapter["n"], task))
        return {}


def run_auto(opts, client, fallback):
    engine = AutoEngine(lambda: NotebookLMEngine(client, ENUMS, opts), lambda: fallback, opts.log)
    return asyncio.run(run(opts, engine))


def counting(client, method):
    """Count calls to one of the client's artifact methods."""
    calls = []
    original = getattr(client.artifacts, method)

    async def counted(*args, **kwargs):
        calls.append(kwargs)
        return await original(*args, **kwargs)

    setattr(client.artifacts, method, counted)
    return calls


# ---- 1. a request whose answer was lost is never asked for again ----


def test_a_request_whose_answer_was_lost_is_found_in_the_notebook_and_waited_for(options):
    """CREATE_ARTIFACT can time out after NotebookLM took the request: asking again would spend its
    allowance twice (up to four podcasts), so the run looks for the one it asked for and waits for it."""
    client = FakeLostReplyClient()
    state = run_with(options, client)
    first = state.chapters[0]["tasks"]
    assert all(first[t]["status"] == DONE for t in ("quiz", "cards", "audio", "video"))
    assert (client.asked.count("audio"), client.asked.count("video")) == (1, 1)
    assert client.asked.count("quiz") == 2  # once per chapter


class LostQuizClient(FakeClient):
    """The quiz request times out and NotebookLM never got it: there's nothing to find."""

    def __init__(self):
        super().__init__(delay=0)
        self.quiz_asks = 0

    async def _generate_quiz(self, notebook_id, source_ids=None, **kwargs):
        self.quiz_asks += 1
        raise RPCTimeoutError("Request timed out calling CREATE_ARTIFACT")


def test_a_request_that_cannot_be_confirmed_waits_for_the_next_run_instead_of_asking_again(options):
    options.chapters, options.media = "1", "none"
    client = LostQuizClient()
    state = run_with(options, client)
    quiz = state.chapters[0]["tasks"]["quiz"]
    assert quiz["status"] == WAITING and client.quiz_asks == 1
    assert quiz.get("requestedAt")  # the next run looks for it before asking again


def test_the_next_run_finds_a_request_the_last_run_could_not_confirm(options):
    options.chapters, options.media = "1", "none"
    run_with(options, LostQuizClient())
    client = FakeClient(delay=0)
    # NotebookLM did get it after all: it's in the notebook now.
    found = SimpleNamespace(
        id="source-1|quiz-0", kind="quiz", source_ids=("source-1",), created_at=datetime.now()
    )
    client.made.append(found)
    asked = counting(client, "generate_quiz")
    state = run_with(options, client)
    quiz = state.chapters[0]["tasks"]["quiz"]
    assert quiz["status"] == DONE and asked == []
    assert "requestedAt" not in quiz and "taskId" not in quiz


# ---- 2. NotebookLM saying it couldn't make it ----


class EndsWith(FakeClient):
    """Every quiz, podcast and video ends with `status` (NotebookLM's GenerationStatus)."""

    def __init__(self, status):
        super().__init__(delay=0)
        self.status = status

    async def _wait(self, notebook_id, task_id, **kwargs):
        if any(f"|{kind}" in task_id for kind in ("quiz", "audio", "video")):
            return self.status
        return await super()._wait(notebook_id, task_id, **kwargs)


RATE_LIMITED = SimpleNamespace(
    status="failed", error="Something went wrong", error_code="USER_DISPLAYABLE_ERROR", is_rate_limited=True
)
BROKEN = SimpleNamespace(status="failed", error="Generation failed", error_code=None, is_rate_limited=False)


def test_a_generation_notebooklm_refused_for_its_limit_waits_for_the_limit(options):
    state = run_with(options, EndsWith(RATE_LIMITED))
    first = state.chapters[0]["tasks"]
    assert (first["audio"]["status"], first["video"]["status"], first["quiz"]["status"]) == (WAITING,) * 3
    assert "limit" in first["audio"]["error"].lower()
    assert first["cards"]["status"] == DONE


def test_a_generation_notebooklm_could_not_finish_fails_with_its_reason(options):
    state = run_with(options, EndsWith(BROKEN))
    audio = state.chapters[0]["tasks"]["audio"]
    assert audio["status"] == FAILED and "Generation failed" in audio["error"]


def test_with_auto_a_failed_podcast_is_never_made_locally_but_a_failed_quiz_is(options):
    fallback = LocalStandIn()
    state = run_auto(options, EndsWith(BROKEN), fallback)
    first = state.chapters[0]["tasks"]
    assert (first["audio"]["status"], first["video"]["status"]) == (FAILED, FAILED)
    assert first["quiz"]["status"] == DONE and first["quiz"]["by"] == "Ollama"
    assert not any(task in ("audio", "video") for _, task in fallback.made)


# ---- 3. adding chapters as sources, patiently ----


class AddsFail(FakeClient):
    """Adding a chapter fails: the first `times` adds of any chapter, or every add of chapter `only`."""

    def __init__(self, error, times=0, only=None):
        super().__init__(delay=0)
        self.error, self.times, self.only, self.adds = error, times, only, 0

    async def _add_file(self, notebook_id, path, **kwargs):
        self.adds += 1
        title = kwargs.get("title") or str(path)
        if self.adds <= self.times or (self.only and title.startswith(f"{self.only:02d} ")):
            raise self.error
        return await super()._add_file(notebook_id, path, **kwargs)


def test_a_hiccup_adding_a_chapter_is_retried(options):
    client = AddsFail(TimeoutError("Request timed out calling ADD_SOURCE"), times=1)
    state = run_with(options, client)
    assert all(c["sourceId"] for c in state.chapters)
    assert all(c["tasks"]["study"]["status"] == DONE for c in state.chapters)


@pytest.mark.parametrize(
    "error",
    [
        RuntimeError("RateLimitError: source limit reached for this notebook"),
        TimeoutError("Request timed out calling ADD_SOURCE"),
    ],
)
def test_a_chapter_notebooklm_would_not_take_waits_while_the_others_carry_on_with_notebooklm(options, error):
    """auto keeps NotebookLM for chapters it has; the other chapter's items wait (never made locally)."""
    fallback = LocalStandIn()
    state = run_auto(options, AddsFail(error, only=2), fallback)
    first, second = (c["tasks"] for c in state.chapters)
    assert all(first[t]["status"] == DONE and first[t]["by"] == "NotebookLM" for t in ("study", "audio"))
    assert {e["status"] for e in second.values() if e["status"] != "skipped"} == {WAITING}
    assert fallback.made == [] and state.chapters[1]["sourceId"] is None
    assert state.data["engine"] == "auto"


def test_a_chapter_added_later_is_picked_up_by_the_next_run(options):
    run_with(options, AddsFail(RuntimeError("source limit reached"), only=2))
    state = run_with(options, FakeClient(delay=0))
    assert state.chapters[1]["sourceId"] and state.chapters[1]["tasks"]["study"]["status"] == DONE


# ---- 4. a notebook or source that's gone ----


class NotebookNotFoundError(Exception):
    """notebooklm-py's name (a NotFoundError and an RPCError)."""


class SourceNotFoundError(Exception):
    """notebooklm-py's name (a NotFoundError and an RPCError)."""


class Gone(FakeClient):
    """Notebooks in `notebooks` and sources in `sources` are gone (deleted, or another Google account)."""

    def __init__(self, notebooks=(), sources=(), every_notebook=False, every_source=False):
        super().__init__(delay=0)
        self.gone_notebooks, self.gone_sources = set(notebooks), set(sources)
        self.every_notebook, self.every_source = every_notebook, every_source
        self.adds: list[str] = []

    def _check(self, notebook_id, source_ids=()):
        if self.every_notebook or notebook_id in self.gone_notebooks:
            raise NotebookNotFoundError(f"Notebook not found: {notebook_id}")
        for source in source_ids or ():
            if self.every_source or source in self.gone_sources:
                raise SourceNotFoundError(f"Source not found: {source}")

    async def _create_notebook(self, title):
        self.notebooks_created += 1
        return SimpleNamespace(id=f"fresh-notebook-{self.notebooks_created}")

    async def _add_file(self, notebook_id, path, **kwargs):
        self._check(notebook_id)
        source_id = f"new-source-{len(self.adds) + 1}"
        self.adds.append(source_id)
        self.source_titles[source_id] = kwargs.get("title") or str(path)
        return SimpleNamespace(id=source_id)

    async def _ask(self, notebook_id, prompt, source_ids=None, **kwargs):
        self._check(notebook_id, source_ids)
        return await super()._ask(notebook_id, prompt, source_ids, **kwargs)

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        self._check(notebook_id, source_ids)
        return await super()._generate(notebook_id, source_ids, **kwargs)

    async def _generate_mind_map(self, notebook_id, source_ids=None, **kwargs):
        self._check(notebook_id, source_ids)
        return await super()._generate_mind_map(notebook_id, source_ids, **kwargs)


def test_a_deleted_notebook_is_made_again_and_the_chapters_still_needed_added_again(options):
    run_with(options, FakeQuotaClient(delay=0))  # chapter 1's podcast and video wait
    client = Gone(notebooks={"dry-notebook"})
    state = run_with(options, client)
    first = state.chapters[0]["tasks"]
    assert (first["audio"]["status"], first["video"]["status"]) == (DONE, DONE)
    assert client.notebooks_created == 1 and state.data["notebookId"] == "fresh-notebook-1"
    assert state.chapters[0]["sourceId"] == "new-source-1" and client.adds == ["new-source-1"]
    assert state.chapters[1]["sourceId"] is None  # nothing left to make there


def test_a_deleted_notebook_found_while_adding_a_chapter_is_made_again(options):
    options.chapters = "1"
    run_with(options, FakeClient(delay=0))
    options.chapters = "all"
    client = Gone(notebooks={"dry-notebook"})
    state = run_with(options, client)
    assert state.chapters[1]["tasks"]["study"]["status"] == DONE
    assert client.notebooks_created == 1 and state.data["notebookId"] == "fresh-notebook-1"


def test_a_notebook_that_keeps_vanishing_is_made_again_only_once_per_run(options):
    client = Gone(every_notebook=True)
    state = run_with(options, client)
    assert client.notebooks_created == 2  # the first, and one more
    assert state.chapters[0]["tasks"]["study"]["status"] == FAILED


def test_a_deleted_source_is_added_again(options):
    run_with(options, FakeQuotaClient(delay=0))
    client = Gone(sources={"source-1"})
    state = run_with(options, client)
    first = state.chapters[0]["tasks"]
    assert (first["audio"]["status"], first["video"]["status"]) == (DONE, DONE)
    assert state.chapters[0]["sourceId"] == "new-source-1" and client.adds == ["new-source-1"]


def test_a_source_that_keeps_vanishing_is_added_again_only_once(options):
    run_with(options, FakeQuotaClient(delay=0))
    client = Gone(every_source=True)
    state = run_with(options, client)
    assert state.chapters[0]["tasks"]["audio"]["status"] == FAILED
    assert len(client.adds) == 1


# ---- 6. asked for in one run, collected in the next ----


class NeverDoneInTime(FakeClient):
    """Podcasts are still being made whenever the run's whole wait runs out."""

    async def _wait(self, notebook_id, task_id, **kwargs):
        if "|audio" in task_id:
            raise WaitTimeoutError(f"Task {task_id} did not complete")
        return await super()._wait(notebook_id, task_id, **kwargs)


def test_a_podcast_still_being_made_is_collected_by_the_next_run_not_asked_for_again(options):
    first_client = NeverDoneInTime(delay=0)
    state = run_with(options, first_client)
    audio = state.chapters[0]["tasks"]["audio"]
    task_id = audio["taskId"]
    assert audio["status"] == WAITING and [a.id for a in first_client.made if a.kind == "audio"] == [task_id]
    assert json.loads((options.out / "state.json").read_text())["chapters"][0]["tasks"]["audio"]["taskId"]

    client = FakeClient(delay=0)
    client.made.append(
        SimpleNamespace(id=task_id, kind="audio", source_ids=("source-1",), created_at=datetime.now())
    )
    asked = counting(client, "generate_audio")
    state = run_with(options, client)
    audio = state.chapters[0]["tasks"]["audio"]
    assert audio["status"] == DONE and asked == []
    assert "taskId" not in audio and "requestedAt" not in audio


def test_a_podcast_notebooklm_no_longer_lists_is_asked_for_again(options):
    run_with(options, NeverDoneInTime(delay=0))
    client = FakeClient(delay=0)  # lists nothing: it was deleted
    asked = counting(client, "generate_audio")
    state = run_with(options, client)
    assert state.chapters[0]["tasks"]["audio"]["status"] == DONE and len(asked) == 1


def test_the_request_is_saved_as_soon_as_it_is_made(options):
    options.chapters, options.media = "1", "none"
    seen = []

    class Peeking(FakeClient):
        async def _wait(self, notebook_id, task_id, **kwargs):
            saved = json.loads((options.out / "state.json").read_text())
            seen.append(saved["chapters"][0]["tasks"]["quiz"].get("taskId"))
            return await super()._wait(notebook_id, task_id, **kwargs)

    client = Peeking(delay=0)
    run_with(options, client)
    assert seen and seen[0] and seen[0].startswith("source-1|quiz")


# ---- 7. a dead session isn't reopened without end ----


def test_a_session_that_never_recovers_is_reopened_only_a_few_times_per_run(options):
    opened = []

    async def reopen():
        opened.append(1)
        return FakeStaleTwiceWhileWaitingClient(stale=1_000)

    options.media = "all"
    engine = NotebookLMEngine(None, ENUMS, options, open_client=reopen)
    state = asyncio.run(run(options, engine))
    assert len(opened) <= 1 + 6
    assert state.chapters[0]["tasks"]["audio"]["status"] == WAITING


# ---- 8. a chapter NotebookLM took but is slow to read is never added twice ----


def statuses(chapter):
    return {e["status"] for e in chapter["tasks"].values() if e["status"] != "skipped"}


def test_a_chapter_notebooklm_is_slow_to_read_is_added_once_and_waited_for_across_runs(options):
    """The add's own wait runs out after NotebookLM made the source: uploading again would make a duplicate
    (four a run, more every run). The source's id is kept and the next run waits for that same source."""
    client = FakeSlowSourceClient(only=2, slow=1)
    fallback = LocalStandIn()
    state = run_auto(options, client, fallback)
    second = state.chapters[1]
    assert [t[:3] for t in client.uploads] == ["01 ", "02 "]
    assert second["sourceId"] == "source-2" and second.get("sourceReady") is False
    assert statuses(second) == {WAITING} and fallback.made == []
    assert statuses(state.chapters[0]) == {DONE}

    state = run_with(options, client)  # still reading it
    assert len(client.uploads) == 2 and client.ready_waits == 1
    assert statuses(state.chapters[1]) == {WAITING} and state.chapters[1]["sourceId"] == "source-2"

    state = run_with(options, client)  # ready now
    assert len(client.uploads) == 2
    assert statuses(state.chapters[1]) == {DONE} and "sourceReady" not in state.chapters[1]


class GoneThenSlow(Gone):
    """Chapter 1's source is gone, and NotebookLM is slow reading the one added in its place."""

    def __init__(self):
        super().__init__(sources={"source-1"})
        self.ready_waits = 0

    async def _add_file(self, notebook_id, path, **kwargs):
        source = await super()._add_file(notebook_id, path, **kwargs)
        raise SourceTimeoutError(source.id)

    async def _wait_until_ready(self, notebook_id, source_id, **kwargs):
        self.ready_waits += 1
        raise SourceTimeoutError(source_id)


def test_a_source_added_again_mid_run_but_still_being_read_leaves_the_chapters_items_waiting(options):
    run_with(options, FakeQuotaClient(delay=0))  # chapter 1's podcast and video wait
    client = GoneThenSlow()
    state = run_with(options, client)
    first = state.chapters[0]
    assert (first["tasks"]["audio"]["status"], first["tasks"]["video"]["status"]) == (WAITING, WAITING)
    assert client.adds == ["new-source-1"] and client.ready_waits == 0
    assert first["sourceId"] == "new-source-1" and first["sourceReady"] is False


def test_a_chapter_notebooklm_could_not_read_is_not_uploaded_again_and_its_broken_source_is_removed(options):
    client = FakeSlowSourceClient(only=2, broken=True)
    state = run_with(options, client)
    second = state.chapters[1]
    assert [t[:3] for t in client.uploads] == ["01 ", "02 "]
    assert client.deleted == ["source-2"] and not second.get("sourceId")
    assert statuses(second) == {FAILED}


# ---- 9. an item NotebookLM made but that couldn't be downloaded is downloaded again, not made again ----


@pytest.mark.parametrize("kind", ["audio", "video", "quiz"])
def test_an_item_made_but_not_downloaded_is_downloaded_by_the_next_run_not_made_again(options, kind):
    client = FakeDownloadFailsClient(kinds=(kind,), times=1)
    fallback = LocalStandIn()
    state = run_auto(options, client, fallback)
    entry = state.chapters[0]["tasks"][kind]
    assert entry["status"] == WAITING and entry["taskId"]
    assert not any(task == kind for _, task in fallback.made)

    state = run_auto(options, client, LocalStandIn())
    entry = state.chapters[0]["tasks"][kind]
    assert entry["status"] == DONE and entry["by"] == "NotebookLM"
    assert client.generated.count(f"source-1:{kind}") == 1
    assert not {"taskId", "requestedAt", "downloadTries"} & set(entry)


def test_an_item_that_never_downloads_stops_after_a_few_runs(options):
    client = FakeDownloadFailsClient(kinds=("audio", "quiz"), times=1_000)
    for _ in range(config.NOTEBOOKLM_DOWNLOAD_TRIES - 1):
        state = run_auto(options, client, LocalStandIn())
        assert state.chapters[0]["tasks"]["audio"]["status"] == WAITING
    fallback = LocalStandIn()
    state = run_auto(options, client, fallback)
    tasks = state.chapters[0]["tasks"]
    assert tasks["audio"]["status"] == FAILED and "taskId" not in tasks["audio"]
    assert tasks["quiz"]["status"] == DONE and tasks["quiz"]["by"] == "Ollama"  # text may be made locally
    assert (1, "audio") not in fallback.made
    assert client.generated.count("source-1:audio") == 1
