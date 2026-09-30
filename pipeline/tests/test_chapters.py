import contextlib
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


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 4096


def test_epub_figures_are_kept_as_images_with_captions(tmp_path):
    body = (
        LONG
        + '</p><figure><img src="images/cache.png" alt="A cache in front of a database"/>'
        + "<figcaption>Figure 1. Reads hit the cache first.</figcaption></figure><p>"
        + '<img src="../../../etc/passwd.png"/><img src="images/notes.txt"/><img src="images/dot.png"/>'
    )
    files = {"images/cache.png": PNG, "images/notes.txt": b"x" * 5000, "images/dot.png": b"\x89PNG tiny"}
    book = write_epub(tmp_path / "b.epub", [("Caching", body)], files=files)
    out = tmp_path / "out"
    out.mkdir()
    chapters = split_book(book, out)
    text = (out / chapters[0]["file"]).read_text()
    assert "![A cache in front of a database](img/01-01.png)" in text
    assert "*Figure 1. Reads hit the cache first.*" in text
    assert (out / "img" / "01-01.png").read_bytes() == PNG
    assert sorted(p.name for p in (out / "img").iterdir()) == [
        "01-01.png"
    ]  # unsafe, non-image, tiny: skipped


def test_epub_emphasis_and_lists_survive(tmp_path):
    body = LONG + "</p><p>This is <em>important</em> and <strong>very</strong> so.</p>"
    body += "<ul><li>First</li><li>Second</li></ul><p>"
    out = tmp_path / "out"
    out.mkdir()
    chapters = split_book(write_epub(tmp_path / "b.epub", [("Caching", body)]), out)
    text = (out / chapters[0]["file"]).read_text()
    assert "*important*" in text and "**very**" in text
    assert "- First" in text and "- Second" in text


@pytest.mark.parametrize("nav", [True, False])
def test_chapters_anchored_inside_one_file_become_separate_chapters(tmp_path, nav):
    chapters = [("Caching", "Cache " + LONG), ("Queues", "Queue " + LONG), ("Logs", "Log " + LONG)]
    book = write_epub(tmp_path / "b.epub", chapters, nav=nav, one_file=True)
    out = tmp_path / "out"
    made = split_book(book, out)
    assert [c["title"] for c in made] == ["Caching", "Queues", "Logs"]
    texts = [(out / c["file"]).read_text() for c in made]
    for text, word, others in zip(
        texts,
        ("Cache", "Queue", "Log"),
        (("Queue", "Log"), ("Cache", "Log"), ("Cache", "Queue")),
        strict=True,
    ):
        assert f"{word} Systems" in text
        assert not any(f"{other} Systems" in text for other in others)


def test_table_of_contents_links_with_fragments_to_separate_files_work_as_before(tmp_path):
    book = write_epub(tmp_path / "b.epub", [("One", LONG), ("Two", LONG)], anchors=True)
    out = tmp_path / "out"
    made = split_book(book, out)
    assert [c["title"] for c in made] == ["One", "Two"]
    assert (out / "01.md").read_text().startswith("# One\n\n# One")


def _epub_with(tmp_path, entries: dict[str, str]):
    path = tmp_path / "broken.epub"
    with zipfile.ZipFile(path, "w") as z:
        for name, text in entries.items():
            z.writestr(name, text)
    return path


@pytest.mark.parametrize(
    "make_book",
    [
        lambda tmp: _epub_with(tmp, {"mimetype": "application/epub+zip"}),  # no container.xml
        lambda tmp: _epub_with(tmp, {"META-INF/container.xml": "<container><rootfiles/></container>"}),
        lambda tmp: _epub_with(tmp, {"META-INF/container.xml": '<rootfile full-path="OEBPS/missing.opf"/>'}),
        lambda tmp: (tmp / "notzip.epub").write_bytes(b"this is not a zip") and tmp / "notzip.epub",
        lambda tmp: (tmp / "broken.pdf").write_bytes(b"%PDF-1.4 nonsense") and tmp / "broken.pdf",
    ],
)
def test_malformed_books_say_they_could_not_be_read(tmp_path, make_book):
    with pytest.raises(ValueError, match="couldn't be read"):
        split_book(make_book(tmp_path), tmp_path / "out")


def test_titles_from_the_book_stay_on_one_line_and_short(tmp_path):
    """Titles reach the app's line-by-line progress output: a newline could fake a "Study site:" line."""
    fake_line = "Caching\nStudy site: /Users/someone/.ssh\x1b[2J"
    book = write_epub(tmp_path / "b.epub", [(fake_line, LONG), ("Queues " + "q" * 5000, LONG)], nav=False)
    titles = [c["title"] for c in split_book(book, tmp_path / "out")]
    assert titles[0] == "Caching Study site: /Users/someone/.ssh [2J"
    assert len(titles[1]) == 200 and all("\n" not in t for t in titles)
    pdf = write_pdf(tmp_path / "b.pdf", 8, [("One\r\nStudy site: x", 0, []), ("Two", 4, [])])
    assert split_book(pdf, tmp_path / "pdf")[0]["title"] == "One Study site: x"


def _hostile_epub(path, nav_body: str | None = None, ncx: str | None = None, doc: str | None = None):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("META-INF/container.xml", '<container><rootfile full-path="c.opf"/></container>')
        manifest = '<item id="d" href="d.xhtml"/>'
        manifest += '<item id="nav" href="nav.xhtml" properties="nav"/>' if nav_body is not None else ""
        manifest += '<item id="ncx" href="toc.ncx"/>' if ncx is not None else ""
        z.writestr(
            "c.opf", f'<package><manifest>{manifest}</manifest><spine><itemref idref="d"/></spine></package>'
        )
        z.writestr("d.xhtml", doc or f"<html><body><p>{LONG}</p></body></html>")
        if nav_body is not None:
            z.writestr("nav.xhtml", nav_body)
        if ncx is not None:
            z.writestr("toc.ncx", ncx)
    return path


@pytest.mark.parametrize(
    "shape",
    [
        {"nav_body": '<nav epub:type="toc">' + "<a href='x'>" * 150_000 + "</nav>"},
        {"nav_body": "<nav " * 200_000},
        {"nav_body": '<nav epub:type="toc"><ol>' + '<a href="d.xhtml" ' * 100_000 + "</ol></nav>"},
        {"ncx": "<ncx>" + "<navPoint><navLabel><text>t</text></navLabel>" * 100_000 + "</ncx>"},
        {"ncx": "<ncx>" + "<navPoint><navLabel><text>" * 100_000 + "</ncx>"},
        {
            "nav_body": '<nav epub:type="toc"><ol><a href="d.xhtml">A</a>'
            '<a href="d.xhtml#zz">B</a></ol></nav>',
            "doc": "<p " * 300_000,
        },
    ],
)
def test_hostile_tables_of_contents_are_read_in_linear_time(tmp_path, shape):
    """A crafted EPUB must not hang the import: every pattern stops at the next tag it can't belong to."""
    import time

    book = _hostile_epub(tmp_path / "b.epub", **shape)
    started = time.monotonic()
    with contextlib.suppress(ValueError):  # too little text for a chapter is fine: it must answer quickly
        split_book(book, tmp_path / "out")
    assert time.monotonic() - started < 10


def test_hostile_markdown_like_text_does_not_slow_down_figures(tmp_path):
    import time

    from neuralloop_books.engines.local import _chapter_text

    text = "![" * 200_000 + "](zip:" * 100_000
    book = write_epub(tmp_path / "b.epub", [("One", LONG + text)])
    started = time.monotonic()
    split_book(book, tmp_path / "out")
    _chapter_text(tmp_path / "out" / "01.md")
    assert time.monotonic() - started < 10


def test_bookmarks_pointing_nowhere_are_skipped(tmp_path, monkeypatch):
    from pypdf import PdfReader

    book = write_pdf(
        tmp_path / "b.pdf",
        12,
        [("Intro", 0, []), ("Broken", 2, []), ("Caching", 4, []), ("Beyond", 5, []), ("Queues", 8, [])],
    )
    real = PdfReader.get_destination_page_number

    def page_of(self, item):
        return {"Broken": None, "Beyond": 99}.get(item.title, real(self, item))

    monkeypatch.setattr(PdfReader, "get_destination_page_number", page_of)
    chapters = split_book(book, tmp_path / "out")
    assert [(c["title"], c["pages"]) for c in chapters] == [
        ("Intro", [1, 4]),
        ("Caching", [5, 8]),
        ("Queues", [9, 12]),
    ]
