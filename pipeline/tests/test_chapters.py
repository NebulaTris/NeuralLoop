import zipfile

import pytest

from neuralloop_books.chapters import UnsafeBookError, is_front_matter, split_book
from neuralloop_books.testing import LONG, write_epub, write_pdf


def test_front_matter_titles():
    assert is_front_matter("Table of Contents") and is_front_matter("  acknowledgments")
    assert not is_front_matter("Contention in databases")


class TestEpub:
    def test_chapters_come_from_the_table_of_contents(self, epub, tmp_path):
        chapters = split_book(epub, tmp_path / "out")
        assert [c["title"] for c in chapters] == [
            "Caching",
            "Queues",
        ]  # cover, contents, and tiny chapter skipped
        text = (tmp_path / "out" / "01.md").read_text()
        assert text.startswith("# Caching") and "## Part one" in text and "x{}" not in text

    def test_ncx_table_of_contents_also_works(self, tmp_path):
        book = write_epub(tmp_path / "b.epub", [("One", LONG), ("Two", LONG)], nav=False)
        assert [c["title"] for c in split_book(book, tmp_path / "out")] == ["One", "Two"]

    def test_unsafe_paths_are_rejected(self, tmp_path):
        bad = tmp_path / "bad.epub"
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("../evil.txt", "x")
        with pytest.raises(UnsafeBookError):
            split_book(bad, tmp_path / "out")


class TestPdf:
    def test_chapters_come_from_bookmarks_and_front_matter_is_skipped(self, tmp_path):
        book = write_pdf(
            tmp_path / "b.pdf",
            12,
            [("Contents", 0, []), ("Intro", 1, []), ("Caching", 4, []), ("Queues", 7, []), ("Index", 10, [])],
        )
        chapters = split_book(book, tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            ("Intro", [2, 4]),
            ("Caching", [5, 7]),
            ("Queues", [8, 10]),
        ]
        assert (tmp_path / "out" / "01.pdf").exists()

    def test_books_divided_into_parts_use_the_chapters_inside(self, tmp_path):
        outline = [("Part I", 0, [("Ch 1", 0), ("Ch 2", 3)]), ("Part II", 6, [("Ch 3", 6), ("Ch 4", 9)])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 12, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == ["Ch 1", "Ch 2", "Ch 3", "Ch 4"]

    def test_without_bookmarks_pages_are_chunked(self, tmp_path):
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 45, []), tmp_path / "out")
        assert [c["pages"] for c in chapters] == [[1, 20], [21, 40], [41, 45]]


def test_other_file_types_are_refused(tmp_path):
    (tmp_path / "x.txt").write_text("hi")
    with pytest.raises(ValueError):
        split_book(tmp_path / "x.txt", tmp_path / "out")
