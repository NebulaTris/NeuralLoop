"""Shared fixtures."""

import pytest

from neuralloop_books.testing import LONG, write_epub


@pytest.fixture
def epub(tmp_path):
    chapters = [
        ("Cover", "c"),
        ("Contents", "toc"),
        ("Caching", LONG),
        ("Queues", LONG),
        ("Tiny", "too short"),
    ]
    return write_epub(tmp_path / "book.epub", chapters)


@pytest.fixture(autouse=True)
def no_video_rendering_unless_asked(monkeypatch):
    """Rendering a real MP4 takes seconds; tests that check it turn it back on."""
    monkeypatch.setenv("NEURALLOOP_VIDEO", "0")


@pytest.fixture(autouse=True)
def never_the_real_notebooklm(monkeypatch):
    """Tests must never reach a real NotebookLM account (the developer's own session is on this machine).
    Tests that need NotebookLM pass a fake client to NotebookLMEngine directly."""
    from neuralloop_books import cli
    from neuralloop_books.models import SetupError

    def unavailable(opts):
        raise SetupError("NotebookLM is switched off in tests")

    monkeypatch.setattr(cli, "_notebooklm_engine", unavailable)
