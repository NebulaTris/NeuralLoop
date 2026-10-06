import asyncio

import pytest

from neuralloop_books.engines.auto import AutoEngine, made_by
from neuralloop_books.models import QuotaError, SetupError


class Recorder:
    def __init__(self, name, fail_prepare=None, fail_make=None):
        self.name, self.fail_prepare, self.fail_make = name, fail_prepare, fail_make
        self.made, self.prepared, self.entered = [], False, False

    async def __aenter__(self):
        self.entered = True
        return self

    async def __aexit__(self, *exc):
        return False

    async def prepare(self, state):
        if self.fail_prepare:
            raise self.fail_prepare
        self.prepared = True

    async def make(self, task, chapter):
        if self.fail_make and task in self.fail_make:
            raise self.fail_make[task]
        self.made.append(task)
        return {task: self.name}


class State:
    def __init__(self):
        self.data = {}

    def save(self):
        pass


def run(engine, *tasks):
    async def go():
        async with engine:
            await engine.prepare(State())
            results = [await engine.make(t, {"n": 1}) for t in tasks]
            for result in results:
                assert result.pop("_by") in ("NotebookLM", "Ollama")  # which engine made it
            return results

    return asyncio.run(go())


def test_notebooklm_is_used_when_it_works():
    primary, fallback = Recorder("NotebookLM"), Recorder("Ollama")
    lines = []
    assert run(AutoEngine(lambda: primary, lambda: fallback, lines.append), "quiz") == [
        {"quiz": "NotebookLM"}
    ]
    assert fallback.made == [] and not fallback.prepared


def test_not_signed_in_uses_the_local_engine_for_everything():
    lines = []
    fallback = Recorder("Ollama")
    engine = AutoEngine(
        lambda: Recorder("NotebookLM", fail_prepare=SetupError("not signed in")),
        lambda: fallback,
        lines.append,
    )
    assert run(engine, "quiz", "audio") == [{"quiz": "Ollama"}, {"audio": "Ollama"}]
    assert engine.name == "Ollama" and any("using Ollama" in line for line in lines)


def test_notebooklm_that_cannot_even_open_falls_back():
    def broken():
        raise RuntimeError("storage file missing")

    fallback = Recorder("Ollama")
    assert run(AutoEngine(broken, lambda: fallback, lambda _: None), "cards") == [{"cards": "Ollama"}]


def test_an_item_notebooklm_fails_or_limits_is_made_locally():
    primary = Recorder(
        "NotebookLM", fail_make={"cards": QuotaError("daily limit"), "quiz": RuntimeError("boom")}
    )
    fallback = Recorder("Ollama")
    lines = []
    results = run(AutoEngine(lambda: primary, lambda: fallback, lines.append), "cards", "quiz", "mindmap")
    assert results == [{"cards": "Ollama"}, {"quiz": "Ollama"}, {"mindmap": "NotebookLM"}]
    assert fallback.prepared and any("quiz" in line and "Ollama" in line for line in lines)


@pytest.mark.parametrize("task", ["audio", "video"])
def test_a_podcast_or_video_at_notebooklms_limit_waits_for_notebooklm(task):
    """People want NotebookLM's own podcasts and videos: at its limit they wait for the reset (the item is
    marked waiting and tried again on the next run) instead of being made on the Mac."""
    primary = Recorder("NotebookLM", fail_make={task: QuotaError("Resource exhausted")})
    fallback = Recorder("Ollama")
    with pytest.raises(QuotaError) as caught:
        run(AutoEngine(lambda: primary, lambda: fallback, lambda _: None), task)
    assert caught.value.engine_name == "NotebookLM"  # reported as NotebookLM's limit
    assert not fallback.prepared  # the Mac never started on it


def test_an_item_fails_normally_when_the_local_fallback_cannot_be_set_up():
    """One NotebookLM hiccup must not stop the whole run because Ollama isn't there."""
    primary = Recorder("NotebookLM", fail_make={"quiz": RuntimeError("boom"), "cards": RuntimeError("bang")})
    attempts = []

    def fallback():
        attempts.append(1)
        raise SetupError("Ollama isn't running")

    engine = AutoEngine(lambda: primary, fallback, lambda _: None)

    async def go():
        async with engine:
            await engine.prepare(State())
            with pytest.raises(RuntimeError, match="boom"):
                await engine.make("quiz", {"n": 1})
            with pytest.raises(RuntimeError, match="bang"):
                await engine.make("cards", {"n": 1})
            return await engine.make("study", {"n": 1})

    assert asyncio.run(go()) == {"study": "NotebookLM", "_by": "NotebookLM"}
    assert len(attempts) == 1  # setup is not retried for every failing item


def test_without_notebooklm_a_fallback_that_cannot_be_set_up_still_stops_the_run():
    def fallback():
        raise SetupError("Ollama isn't running")

    engine = AutoEngine(
        lambda: Recorder("NotebookLM", fail_prepare=SetupError("not signed in")), fallback, lambda _: None
    )

    async def go():
        async with engine:
            await engine.prepare(State())

    with pytest.raises(SetupError, match="Ollama"):
        asyncio.run(go())


class Local(Recorder):
    """Like LocalEngine.prepare: records itself as the book's engine."""

    async def prepare(self, state):
        state.data.update(engine="local", provider="ollama", model="qwen3:8b")
        self.prepared = True


def test_a_mid_run_fallback_keeps_the_book_engine_auto():
    primary = Recorder("NotebookLM", fail_make={"quiz": RuntimeError("boom")})
    engine = AutoEngine(lambda: primary, lambda: Local("Ollama"), lambda _: None)
    state = State()

    async def go():
        async with engine:
            await engine.prepare(state)
            await engine.make("quiz", {"n": 1})

    asyncio.run(go())
    assert state.data == {"engine": "auto", "provider": "ollama", "model": "qwen3:8b"}


def test_a_limit_on_the_local_fallback_is_named_after_the_fallback():
    primary = Recorder("NotebookLM", fail_make={"quiz": RuntimeError("boom")})
    fallback = Recorder("Ollama", fail_make={"quiz": QuotaError("slow down")})
    engine = AutoEngine(lambda: primary, lambda: fallback, lambda _: None)

    async def go():
        async with engine:
            await engine.prepare(State())
            await engine.make("quiz", {"n": 1})

    with pytest.raises(QuotaError) as caught:
        asyncio.run(go())
    assert made_by(caught.value, "Auto") == "Ollama"


def test_a_limited_fallback_is_skipped_but_notebooklm_still_tries_the_item():
    primary = Recorder("NotebookLM", fail_make={"quiz": RuntimeError("boom")})
    fallback = Recorder("Ollama", fail_make={"quiz": QuotaError("slow down")})
    tries = []
    original = fallback.make

    async def counting(task, chapter):
        tries.append(task)
        return await original(task, chapter)

    fallback.make = counting
    engine = AutoEngine(lambda: primary, lambda: fallback, lambda _: None)

    async def go():
        async with engine:
            await engine.prepare(State())
            with pytest.raises(QuotaError):
                await engine.make("quiz", {"n": 1})
            with pytest.raises(RuntimeError, match="boom") as second:
                await engine.make("quiz", {"n": 2})
            primary.fail_make = {}
            return second.value, await engine.make("quiz", {"n": 3})

    second, third = asyncio.run(go())
    assert tries == ["quiz"]  # the limited fallback wasn't asked again
    assert made_by(second, "Auto") == "NotebookLM"
    assert third == {"quiz": "NotebookLM", "_by": "NotebookLM"}


def test_only_an_item_notebooklm_failed_says_so_in_the_progress_feed(monkeypatch):
    from neuralloop_books.engines import auto

    steps = []
    monkeypatch.setattr(auto.activity, "report", lambda step=None, **kw: steps.append((step, kw)))
    local_only = AutoEngine(
        lambda: Recorder("NotebookLM", fail_prepare=SetupError("not signed in")),
        lambda: Recorder("Ollama"),
        lambda _: None,
    )
    run(local_only, "quiz")
    assert steps == []  # NotebookLM was never tried for it

    primary = Recorder("NotebookLM", fail_make={"audio": RuntimeError("generation failed")})
    run(AutoEngine(lambda: primary, lambda: Recorder("Ollama"), lambda _: None), "quiz", "audio")
    assert steps == [("NotebookLM couldn't, so Ollama is making it", {"by": "Ollama", "restart": True})]


def test_a_podcast_notebooklm_could_not_answer_waits_but_a_quiz_is_made_locally():
    from neuralloop_books.notebook import NotebookLMBusy

    busy = NotebookLMBusy("NotebookLM didn't answer (Request timed out) after 4 tries")
    primary = Recorder("NotebookLM", fail_make={"video": busy, "quiz": NotebookLMBusy("slow")})
    fallback = Recorder("Ollama")
    assert run(AutoEngine(lambda: primary, lambda: fallback, lambda _: None), "quiz") == [{"quiz": "Ollama"}]
    with pytest.raises(NotebookLMBusy) as caught:
        run(
            AutoEngine(
                lambda: Recorder("NotebookLM", fail_make={"video": busy}),
                lambda: Recorder("Ollama"),
                lambda _: None,
            ),
            "video",
        )
    assert caught.value.engine_name == "NotebookLM"
