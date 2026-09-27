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
