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
