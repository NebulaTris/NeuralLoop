import asyncio
import json
from pathlib import Path

import pytest

from neuralloop_books.fake_client import ENUMS, FakeClient
from neuralloop_books.models import QuotaError
from neuralloop_books.notebook import (
    ChapterMaker,
    MediaOptions,
    NotebookLMBusy,
    UnusableAnswer,
    is_quota_error,
    is_transient_error,
)


class EmptyClient(FakeClient):
    """NotebookLM finished, but the quiz and cards it made are empty."""

    async def _download_quiz(self, notebook_id, path, task_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps({"title": "Quiz", "questions": []}))
        return path

    async def _download_cards(self, notebook_id, path, task_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps({"title": "Cards", "cards": []}))
        return path


@pytest.mark.parametrize("task", ["quiz", "cards"])
def test_an_empty_quiz_or_card_deck_is_unusable(tmp_path, task):
    media = MediaOptions("deep-dive", "explainer", "kawaii", "en", "")
    maker = ChapterMaker(EmptyClient(delay=0), ENUMS, "nb", tmp_path, media)
    chapter = {"n": 1, "title": "Caching", "sourceId": "source-1", "file": "01.md"}
    with pytest.raises(UnusableAnswer):
        asyncio.run(maker.make(task, chapter))


@pytest.mark.parametrize(
    "error",
    [
        QuotaError("slow down"),
        type("RateLimitError", (Exception,), {})("try later"),
        RuntimeError("You've hit your daily limit reached for audio"),
        RuntimeError("Daily limit reached"),
        RuntimeError("quota exceeded for this project"),
        RuntimeError("RESOURCE_EXHAUSTED: try again"),
        RuntimeError("resource exhausted"),
        RuntimeError("HTTP 429 Too Many Requests"),
        RuntimeError("server returned status 429"),
        RuntimeError("Error 429"),
        RuntimeError("429 Too Many Requests"),
        RuntimeError("rate limit exceeded"),
    ],
)
def test_quota_errors_are_recognised(error):
    assert is_quota_error(error)


@pytest.mark.parametrize(
    "message",
    [
        "couldn't read page 429",
        "timed out after 1429s",
        "source 4291 missing",
        "bad json",
        "recursion depth unlimited",
    ],
)
def test_other_errors_that_mention_numbers_are_not_quota_errors(message):
    assert not is_quota_error(RuntimeError(message))


def _named(name, message, base=Exception, **attrs):
    error = type(name, (base,), {})(message)
    for key, value in attrs.items():
        setattr(error, key, value)
    return error


@pytest.mark.parametrize(
    "error",
    [
        TimeoutError("Request timed out calling LIST_ARTIFACTS"),
        ConnectionResetError("connection reset by peer"),
        _named("RPCTimeoutError", "RPC timed out"),
        _named("ServerError", "Server error", status_code=503),
        _named("ServerError", "something broke", status_code=502),
        RuntimeError("HTTP 503 Service Unavailable"),
        RuntimeError("server returned status 504"),
        RuntimeError("Error 502 from the server"),
        RuntimeError("502 Bad Gateway"),
        RuntimeError("The service is temporarily unavailable"),
        _named("RPCError", "try again", rpc_code="UNAVAILABLE"),
    ],
)
def test_hiccups_are_transient(error):
    assert is_transient_error(error)


@pytest.mark.parametrize(
    "error",
    [
        _named("ArtifactFeatureUnavailableError", "Audio generation is unavailable"),
        RuntimeError("Video generation is unavailable"),
        _named("ArtifactNotFoundError", "Artifact abc not found"),
        _named("SourceNotFoundError", "Source unavailable"),
        _named("ValidationError", "Invalid video style"),
        json.JSONDecodeError("Expecting value", "x" * 600, 504),  # "(char 504)"
        RuntimeError("Chapter 503 is missing"),
        RuntimeError("couldn't parse line 502"),
        RuntimeError("Request timed out: daily limit reached"),  # a limit beats a hiccup
        _named("AuthError", "timed out (unauthenticated)"),  # a sign-in beats a hiccup
        NotebookLMBusy("NotebookLM didn't answer (Request timed out) after 4 tries"),  # already waited out
        UnusableAnswer("timed out answer"),
    ],
)
def test_lasting_problems_are_not_transient(error):
    assert not is_transient_error(error)
