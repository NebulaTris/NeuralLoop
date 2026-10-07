import contextlib
import zipfile

import pytest

from neuralloop_books.chapters import (
    MAX_IMAGES_PER_CHAPTER,
    UnreadableBookError,
    UnsafeBookError,
    is_appendix,
    is_front_matter,
    split_book,
)
from neuralloop_books.testing import LONG, write_epub, write_pdf


def test_front_matter_titles():
    assert is_front_matter("Table of Contents") and is_front_matter("  acknowledgments")
    assert not is_front_matter("Contention in databases")


def test_reading_guides_and_back_matter_are_not_chapters():
    for title in (
        "How to make the most out of this book and your time?",
        "How to use this book",
        "How to read this book",
        "About this book",
        "Glossary",
        "Bibliography",
        "Further reading",
        "Notes",
        "Notes.",
        "Notes and references",
        "References",
        "Index",
        "Index.",
        "Contents",
        "Cover",
        "Copyright",
        "Dedication",
        "Colophon",
        "About the authors",
        "Praise for this book",
        "Also by Martin Kleppmann",
    ):
        assert is_front_matter(title), title
    for title in ("How to build an agent", "Notes on caching", "Referential integrity", "About agents"):
        assert not is_front_matter(title), title


@pytest.mark.parametrize(
    "title",
    [
        "Index structures",
        "Index-free adjacency",
        "Contents of the cache",
        "Cover letters",
        "Copyright law for developers",
        "Dedication to craft",
        "Praise for the reviewers",
        "How to Read a Person Like a Book",
    ],
)
def test_chapters_that_merely_start_like_front_matter_are_kept(title, tmp_path):
    assert not is_front_matter(title)
    pdf = write_pdf(tmp_path / "b.pdf", 12, [("Intro", 0, []), (title, 4, []), ("Queues", 8, [])])
    assert [c["title"] for c in split_book(pdf, tmp_path / "pdf")] == ["Intro", title, "Queues"]
    epub = write_epub(tmp_path / "b.epub", [("Intro", LONG), (title, LONG), ("Queues", LONG)])
    assert [c["title"] for c in split_book(epub, tmp_path / "epub")] == ["Intro", title, "Queues"]


def test_appendices_are_recognised_but_left_to_their_size():
    for title in ("Appendix B: Setting up Python", "Appendix A", "Appendices"):
        assert is_appendix(title) and not is_front_matter(title), title
    assert not is_appendix("Apples and pears")


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

    def test_a_substantial_appendix_is_kept_and_a_short_one_skipped(self, tmp_path):
        chapters = [("One", LONG * 10), ("Two", LONG * 10), ("Three", LONG * 10)]
        chapters += [("Appendix A: Full SQL tutorial", LONG * 20), ("Appendix B: Setting up", LONG)]
        made = split_book(write_epub(tmp_path / "b.epub", chapters), tmp_path / "out")
        assert [c["title"] for c in made] == ["One", "Two", "Three", "Appendix A: Full SQL tutorial"]

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

    def test_a_guidebook_with_blank_bookmarks_a_reading_guide_and_a_long_part_of_projects(self, tmp_path):
        """Shaped like a real guidebook: blank bookmarks, a reading guide and contents up front, one short
        chapter with only section bookmarks inside, and a long part whose bookmarks are whole projects."""
        outline = [
            ("How to make the most out of this book and your time?", 0, [("Table of contents", 0)]),
            (" ", 0, []),
            ("AI Agents", 0, []),
            ("What is an AI Agent?", 5, []),
            ("Agent vs LLM vs RAG", 8, []),
            ("  ", 8, [("LLM", 8), ("RAG", 9)]),
            ("Building blocks", 10, [("1) Roles", 10), ("2) Tasks", 11), ("3) Tools", 12), ("4) Ask", 14)]),
            ("Design patterns", 16, []),
            ("", 20, []),
            ("Projects", 21, [("#1) Agentic RAG", 22), ("", 27), ("#2) Voice RAG", 28), ("#3) Flights", 35),
                              ("#4) Analyst", 42), ("", 48), ("#5) News", 50)]),
        ]  # fmt: skip
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 75, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            ("What is an AI Agent?", [6, 8]),
            ("Agent vs LLM vs RAG", [9, 10]),
            ("Building blocks", [11, 16]),
            ("Design patterns", [17, 21]),
            ("#1) Agentic RAG", [23, 28]),
            ("#2) Voice RAG", [29, 35]),
            ("#3) Flights", [36, 42]),
            ("#4) Analyst", [43, 50]),
            ("#5) News", [51, 75]),
        ]

    def test_a_part_with_a_few_pages_of_its_own_keeps_them_as_a_chapter(self, tmp_path):
        outline = [
            ("One", 0, []),
            ("Two", 5, []),
            ("Projects", 10, [("Alpha", 13), ("Beta", 23), ("Gamma", 33)]),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 45, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == ["One", "Two", "Projects", "Alpha", "Beta", "Gamma"]
        assert chapters[2]["pages"] == [11, 13]

    def test_a_textbook_keeps_whole_chapters_and_skips_part_dividers(self, tmp_path):
        """Shaped like Designing Data-Intensive Applications: parts as their own short bookmarks, then long
        chapters whose bookmarks are sections (each ending in "Summary"). Chapters stay whole."""

        def chapter(n, page, length):
            step = length // 4
            sections = [("Idea A", page + 1), ("Idea B", page + 1 + step), ("Idea C", page + 1 + 2 * step)]
            return (f"Chapter {n}. Topic {n}", page, [*sections, ("Summary", page + length - 4)])

        outline = [
            ("Cover", 0, []),
            ("Table of Contents", 2, []),
            ("About this Book", 6, [("Who Should Read this Book?", 7)]),
            ("Part I. Foundations", 10, []),
            chapter(1, 12, 24),
            chapter(2, 36, 42),
            chapter(3, 78, 40),
            ("Part II. Distributed Data", 118, []),
            chapter(4, 122, 46),
            chapter(5, 168, 52),
            ("Part III. Derived Data", 220, []),
            chapter(6, 222, 48),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 270, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            ("Chapter 1. Topic 1", [13, 36]),
            ("Chapter 2. Topic 2", [37, 78]),
            ("Chapter 3. Topic 3", [79, 118]),
            ("Chapter 4. Topic 4", [123, 168]),
            ("Chapter 5. Topic 5", [169, 220]),
            ("Chapter 6. Topic 6", [223, 270]),
        ]

    def test_a_book_made_of_short_parts_keeps_every_part(self, tmp_path):
        """ "Part 1" to "Part 6", six pages each and nothing inside: the parts are the chapters."""
        outline = [(f"Part {n}", (n - 1) * 6, []) for n in range(1, 7)]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 36, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            (f"Part {n}", [(n - 1) * 6 + 1, n * 6]) for n in range(1, 7)
        ]

    def test_a_short_last_part_is_kept_even_before_the_index(self, tmp_path):
        outline = [
            ("Part One: Basics", 0, []),
            ("Part Two: Tools", 20, []),
            ("Part Three: Practice", 40, []),
            ("Part 4: Projects", 60, []),
            ("Part 5: Exercises", 80, []),
            ("Index", 84, []),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 86, outline), tmp_path / "out")
        assert [c["title"] for c in chapters][-1] == "Part 5: Exercises"
        assert len(chapters) == 5 and chapters[-1]["pages"] == [81, 84]

    def test_when_every_bookmark_is_skipped_pages_are_chunked_rather_than_nothing(self, tmp_path):
        outline = [("Contents", 0, []), ("Index", 1, [])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 30, outline), tmp_path / "out")
        assert [c["pages"] for c in chapters] == [[1, 20], [21, 30]]

    def test_parts_with_front_matter_around_them_open_into_their_chapters(self, tmp_path):
        def part(name, page):
            return (f"Part {name}", page, [(f"{name}.{k} Chapter", page + 2 + 10 * k) for k in range(3)])

        outline = [
            ("Preface", 0, []),
            ("Foreword", 4, []),
            part("I", 8),
            part("II", 40),
            part("III", 72),
            ("Index", 104, []),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 110, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == [
            "Preface",
            "Foreword",
            *(f"{name}.{k} Chapter" for name in ("I", "II", "III") for k in range(3)),
        ]
        assert chapters[4]["pages"] == [31, 40]  # the last chapter of Part I ends where Part II begins

    @pytest.mark.parametrize("section", ["Section {k}", "{n}.{k} Section"])
    def test_short_parts_holding_sections_stay_whole(self, tmp_path, section):
        """ "Part 1: Topic 1" to "Part 5: Topic 5", twelve pages each, each with three four-page sections
        inside: the parts are the chapters."""

        def part(n):
            kids = [(section.format(n=n, k=k), (n - 1) * 12 + 4 * k) for k in range(3)]
            return (f"Part {n}: Topic {n}", (n - 1) * 12, kids)

        outline = [part(n) for n in range(1, 6)]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 60, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            (f"Part {n}: Topic {n}", [(n - 1) * 12 + 1, n * 12]) for n in range(1, 6)
        ]

    def test_parts_of_numbered_chapters_between_a_preface_and_an_index_open_into_the_chapters(self, tmp_path):
        def part(name, first, page):
            return (f"Part {name}", page, [(f"Chapter {first + k}", page + 2 + 30 * k) for k in range(3)])

        outline = [
            ("Preface", 0, []),
            ("Foreword", 4, []),
            part("I", 1, 8),
            part("II", 4, 100),
            part("III", 7, 192),
            ("Index", 284, []),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 290, outline), tmp_path / "out")
        titles = [c["title"] for c in chapters]
        assert [t for t in titles if t.startswith("Chapter")] == [f"Chapter {n}" for n in range(1, 10)]
        assert not any(t.startswith("Part") for t in titles)

    @pytest.mark.parametrize("title", ["12 Projects", "50 Python Projects", "100 Exercises"])
    def test_a_long_part_named_with_a_bare_number_still_opens_into_its_projects(self, tmp_path, title):
        outline = [(name, n * 6, []) for n, name in enumerate(["Intro", "Basics", "Tools", "Setup"])]
        outline += [(title, 24, [(f"Project {k + 1}", 24 + 6 * k) for k in range(12)])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 96, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == [
            "Intro",
            "Basics",
            "Tools",
            "Setup",
            *(f"Project {k + 1}" for k in range(12)),
        ]

    def test_a_child_bookmark_earlier_than_its_part_is_still_its_own_chapter(self, tmp_path):
        outline = [
            ("Intro", 0, []),
            ("Part I", 4, [("Ch 1", 5), ("Ch 2", 10)]),
            ("Part II", 16, [("Ch 3", 15), ("Ch 4", 20)]),
        ]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 26, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            ("Intro", [1, 4]),
            ("Ch 1", [6, 10]),
            ("Ch 2", [11, 15]),
            ("Ch 3", [16, 20]),
            ("Ch 4", [21, 26]),
        ]

    def test_a_single_bookmark_with_chapters_inside_uses_them(self, tmp_path):
        outline = [("The whole book", 0, [("One", 0), ("Two", 10), ("Three", 20)])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 30, outline), tmp_path / "out")
        assert [(c["title"], c["pages"]) for c in chapters] == [
            ("One", [1, 10]),
            ("Two", [11, 20]),
            ("Three", [21, 30]),
        ]

    @pytest.mark.parametrize(
        "title", ["6. Storage and Retrieval", "6 Storage and Retrieval", "6: Storage and Retrieval"]
    )
    def test_long_numbered_chapters_stay_whole(self, tmp_path, title):
        outline = [(f"{n}. Topic {n}", (n - 1) * 10, []) for n in range(1, 6)]
        outline += [(title, 50, [("Hash indexes", 52), ("SSTables", 70), ("B-trees", 90)])]
        outline += [("7. Encoding", 110, [])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 120, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == [
            *(f"{n}. Topic {n}" for n in range(1, 6)),
            title,
            "7. Encoding",
        ]

    def test_a_long_chapter_whose_bookmarks_are_numbered_sections_stays_whole(self, tmp_path):
        outline = [(f"Topic {n}", (n - 1) * 10, []) for n in range(1, 6)]
        outline += [("Storage", 50, [("6.1 Hash indexes", 52), ("6.2 SSTables", 70), ("6.3 B-trees", 90)])]
        outline += [("Encoding", 110, [])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 120, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == [*(f"Topic {n}" for n in range(1, 6)), "Storage", "Encoding"]

    def test_a_substantial_appendix_is_kept_and_a_short_one_skipped(self, tmp_path):
        outline = [(f"Chapter {n}", (n - 1) * 20, []) for n in range(1, 5)]
        outline += [("Appendix A: Full SQL tutorial", 80, []), ("Appendix B: Setting up", 120, [])]
        chapters = split_book(write_pdf(tmp_path / "b.pdf", 123, outline), tmp_path / "out")
        assert [c["title"] for c in chapters] == [
            *(f"Chapter {n}" for n in range(1, 5)),
            "Appendix A: Full SQL tutorial",
        ]

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


# ---------------------------------------------------------------- EPUB tables of contents with levels


def _sectioned(word: str) -> str:
    """A chapter body with two sections that the table of contents links to by anchor."""
    return f'{word} {LONG}</p><h2 id="a">First</h2><p>{LONG}</p><h2 id="b">Second</h2><p>{LONG}'


def _titles(book, out):
    return [c["title"] for c in split_book(book, out)]


class TestEpubContentsWithLevels:
    """A nav document and an NCX with the same levels split the same way, the way PDF bookmarks do:
    parts open into their chapters, chapters keep their sections inside."""

    @pytest.mark.parametrize("nav", [True, False])
    @pytest.mark.parametrize("part_page", [True, False])
    @pytest.mark.parametrize("name", ["Chapter {k}: Topic {p}.{k}", "Topic {p}.{k}"])
    def test_parts_open_into_their_chapters(self, tmp_path, nav, part_page, name):
        """Three parts of four chapters, each chapter its own file (a part's own title page, or none)."""
        chapters, toc = [], []
        for p in range(1, 4):
            if part_page:
                chapters.append((f"Part {p}", "A short opener."))
            first = len(chapters)
            kids = []
            for k in range(1, 5):
                kids.append((name.format(p=p, k=k), len(chapters), []))
                chapters.append((name.format(p=p, k=k), f"Body {p}.{k} {LONG}"))
            toc.append((f"Part {p}", first - 1 if part_page else first, kids))
        book = write_epub(tmp_path / "b.epub", chapters, nav=nav, toc=toc)
        expected = [name.format(p=p, k=k) for p in range(1, 4) for k in range(1, 5)]
        assert _titles(book, tmp_path / "out") == expected
        assert f"Body 2.3 {LONG[:20]}" in (tmp_path / "out" / "07.md").read_text()

    @pytest.mark.parametrize("nav", [True, False])
    @pytest.mark.parametrize("section", ["{n}.{k} Basics", "Basics {k}"])
    def test_chapters_keep_their_sections_inside(self, tmp_path, nav, section):
        names = ["Intro", "Caching", "Queues", "Logs"]
        chapters = [("Intro", LONG)] + [(t, _sectioned(t)) for t in names[1:]]
        toc = [("Intro", 0, [])] + [
            (
                t,
                n,
                [
                    (section.format(n=n, k=1), f"doc{n}.xhtml#a", []),
                    (section.format(n=n, k=2), f"doc{n}.xhtml#b", []),
                ],
            )
            for n, t in enumerate(names)
            if n
        ]
        out = tmp_path / "out"
        assert _titles(write_epub(tmp_path / "b.epub", chapters, nav=nav, toc=toc), out) == names
        text = (out / "02.md").read_text()
        assert "## First" in text and "## Second" in text

    @pytest.mark.parametrize("nav", [True, False])
    def test_one_chapter_with_sections_among_plain_ones_stays_whole(self, tmp_path, nav):
        chapters = [("Intro", LONG), ("Caching", _sectioned("Caching")), ("Queues", LONG)]
        toc = [
            ("Intro", 0, []),
            ("Caching", 1, [("Why caches", "doc1.xhtml#a", []), ("Eviction", "doc1.xhtml#b", [])]),
            ("Queues", 2, []),
        ]
        book = write_epub(tmp_path / "b.epub", chapters, nav=nav, toc=toc)
        assert _titles(book, tmp_path / "out") == ["Intro", "Caching", "Queues"]

    @pytest.mark.parametrize("nav", [True, False])
    def test_parts_chapters_and_sections_mixed_with_front_and_back_matter(self, tmp_path, nav):
        chapters = [
            ("Contents", "toc"),
            ("Preface", LONG),
            ("Part I", "Opener."),
            ("Chapter 1", _sectioned("One")),
            ("Chapter 2", LONG),
            ("Part II", "Opener."),
            ("Chapter 3", LONG),
            ("Chapter 4", _sectioned("Four")),
            ("Appendix A: Full tutorial", LONG * 10),
            ("Index", LONG),
        ]

        def sections(n):
            return [(f"{n}.1 First", f"doc{n}.xhtml#a", []), (f"{n}.2 Second", f"doc{n}.xhtml#b", [])]

        toc = [
            ("Contents", 0, []),
            ("Preface", 1, []),
            ("Part I", 2, [("Chapter 1", 3, sections(3)), ("Chapter 2", 4, [])]),
            ("Part II", 5, [("Chapter 3", 6, []), ("Chapter 4", 7, sections(7))]),
            ("Appendix A: Full tutorial", 8, []),
            ("Index", 9, []),
        ]
        book = write_epub(tmp_path / "b.epub", chapters, nav=nav, toc=toc)
        assert _titles(book, tmp_path / "out") == [
            "Preface",
            "Chapter 1",
            "Chapter 2",
            "Chapter 3",
            "Chapter 4",
            "Appendix A: Full tutorial",
        ]

    @pytest.mark.parametrize("nav", [True, False])
    def test_a_single_entry_for_the_whole_book_opens_into_its_chapters(self, tmp_path, nav):
        chapters = [("My Book", "Title page."), ("Caching", LONG), ("Queues", LONG), ("Logs", LONG)]
        toc = [("My Book", 0, [("Caching", 1, []), ("Queues", 2, []), ("Logs", 3, [])])]
        book = write_epub(tmp_path / "b.epub", chapters, nav=nav, toc=toc)
        assert _titles(book, tmp_path / "out") == ["Caching", "Queues", "Logs"]

    def test_part_headings_without_links_still_give_their_chapters(self, tmp_path):
        chapters = [("Caching", LONG), ("Queues", LONG), ("Logs", LONG)]
        toc = [
            ("Part I", None, [("Caching", 0, []), ("Queues", 1, [])]),
            ("Part II", None, [("Logs", 2, [])]),
        ]
        book = write_epub(tmp_path / "b.epub", chapters, toc=toc)
        assert _titles(book, tmp_path / "out") == ["Caching", "Queues", "Logs"]


# ---------------------------------------------------------------- EPUBs of short pieces

ESSAY = ("Short thoughts on habits and the days they shape. " * 30)[:1250]


def test_a_book_of_short_essays_is_grouped_rather_than_refused(tmp_path):
    from neuralloop_books.chapters import MIN_EPUB_CHARS

    essays = [(f"Essay {i}", f"Mark{i}. {ESSAY}") for i in range(1, 31)]
    out = tmp_path / "out"
    made = split_book(write_epub(tmp_path / "b.epub", essays), out)
    assert len(made) >= 2 and made[0]["title"] == "Essay 1 and more"
    texts = [(out / c["file"]).read_text() for c in made]
    assert all(len(text) >= MIN_EPUB_CHARS for text in texts)
    joined = "".join(texts)
    positions = [joined.index(f"Mark{i}. ") for i in range(1, 31)]  # every essay, once, in order
    assert positions == sorted(positions) and all(joined.count(f"Mark{i}. ") == 1 for i in range(1, 31))


def test_a_long_chapter_does_not_hide_the_short_pieces_around_it(tmp_path):
    essays = [("Introduction", LONG)] + [(f"Essay {i}", f"Mark{i}. {ESSAY}") for i in range(1, 21)]
    out = tmp_path / "out"
    made = split_book(write_epub(tmp_path / "b.epub", essays), out)
    assert made[0]["title"] == "Introduction" and len(made) > 2
    joined = "".join((out / c["file"]).read_text() for c in made)
    assert all(f"Mark{i}. " in joined for i in range(1, 21))


def test_a_very_short_book_is_one_chapter(tmp_path):
    made = split_book(write_epub(tmp_path / "b.epub", [("A poem", "Roses are red.")]), tmp_path / "out")
    assert [c["title"] for c in made] == ["A poem"]


def test_a_book_with_no_text_at_all_says_it_could_not_be_read(tmp_path):
    with pytest.raises(UnreadableBookError, match="This book couldn't be read"):
        split_book(write_epub(tmp_path / "b.epub", [("Cover", "")]), tmp_path / "out")


# ---------------------------------------------------------------- cheap work on hostile books


def test_figures_are_sized_up_before_they_are_read_and_read_at_most_once(tmp_path, monkeypatch):
    big = PNG + b"\x00" * 10_000
    files = {"images/dot.png": b"\x89PNG tiny", "images/big.png": big}
    files |= {f"images/f{k}.png": PNG for k in range(100)}
    body = LONG + "</p>"
    body += '<img src="images/dot.png"/><img src="images/big.png"/>' * 200
    body += "".join(f'<img src="images/f{k}.png"/>' for k in range(100)) + "<p>"
    book = write_epub(tmp_path / "b.epub", [("Figures", body)], files=files)
    reads: dict[str, int] = {}
    real_read = zipfile.ZipFile.read

    def counting_read(self, name, pwd=None):
        key = name if isinstance(name, str) else name.filename
        reads[key] = reads.get(key, 0) + 1
        return real_read(self, name, pwd)

    monkeypatch.setattr(zipfile.ZipFile, "read", counting_read)
    out = tmp_path / "out"
    split_book(book, out)
    assert "OEBPS/images/dot.png" not in reads  # too small to be a figure: never read
    assert reads["OEBPS/images/big.png"] == 1
    figures = sum(n for name, n in reads.items() if "/f" in name)
    assert figures == MAX_IMAGES_PER_CHAPTER - 1 and all(n == 1 for name, n in reads.items() if "/f" in name)
    assert len(list((out / "img").iterdir())) == MAX_IMAGES_PER_CHAPTER


def test_many_chapters_anchored_in_one_file_are_all_found(tmp_path):
    chapters = [(f"Topic {i}", f"Mark{i}. " + LONG) for i in range(300)]
    out = tmp_path / "out"
    made = split_book(write_epub(tmp_path / "b.epub", chapters, one_file=True), out)
    assert [c["title"] for c in made] == [f"Topic {i}" for i in range(300)]
    assert "Mark150. " in (out / "151.md").read_text()


def test_anchor_offsets_finds_every_id_and_name_in_one_pass():
    from neuralloop_books.chapters import _anchor_offsets

    text = '<p id="a">x</p><a name=\'b\' id="c"/><p id="a">again</p><p class="x" id="d">'
    assert _anchor_offsets(text) == {"a": 0, "b": 15, "c": 15, "d": text.index('<p class="x"')}


def test_where_each_bookmark_ends_is_the_next_later_start():
    from neuralloop_books.chapters import _next_starts

    assert _next_starts([0, 0, 3, 3, 7], 10) == [3, 3, 7, 7, 10]
    assert _next_starts([], 10) == []
