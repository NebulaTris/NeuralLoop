import asyncio

from neuralloop_books.engines.auto import AutoEngine
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
