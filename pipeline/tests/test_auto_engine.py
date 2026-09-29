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
        "NotebookLM", fail_make={"video": QuotaError("daily limit"), "quiz": RuntimeError("boom")}
    )
    fallback = Recorder("Ollama")
    lines = []
    results = run(AutoEngine(lambda: primary, lambda: fallback, lines.append), "cards", "quiz", "video")
    assert results == [{"cards": "NotebookLM"}, {"quiz": "Ollama"}, {"video": "Ollama"}]
    assert fallback.prepared and any("quiz" in line and "Ollama" in line for line in lines)


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
