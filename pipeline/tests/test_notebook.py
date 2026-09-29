import asyncio
import json
from pathlib import Path

import pytest

from neuralloop_books.fake_client import ENUMS, FakeClient
from neuralloop_books.models import QuotaError
from neuralloop_books.notebook import ChapterMaker, MediaOptions, UnusableAnswer, is_quota_error


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
