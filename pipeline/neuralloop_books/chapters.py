"""Split a book into chapter files. PDFs keep their pages; EPUBs become Markdown."""

import html
import re
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from posixpath import dirname, join, normpath
from typing import ClassVar
from urllib.parse import unquote, urldefrag

from .config import APPENDIX, FRONT_MATTER, MAX_BOOK_IMAGE_BYTES

MIN_PDF_PAGES = 2
MIN_EPUB_CHARS = 1500
FALLBACK_PAGES = 20
LONG_PART_PAGES = 30  # a bookmark this long, with bookmarks inside...
MIN_SECTION_PAGES = 4  # ...averaging this many pages each holds whole chapters (projects, say), not sections
PART_SIZE = 3  # ...if it's also this many times as long as the book's typical chapter
MAX_DIVIDER_PAGES = (
    8  # a "Part II" bookmark this short, with chapters after it, is the part's title page and intro
)
DIVIDER_SHARE = 4  # ...as is one with nothing after it that's a quarter of a typical chapter or less
PAGE_CHARS = 2_500  # a typical book page
MIN_APPENDIX_PAGES = 8  # an appendix this long (or half a typical chapter, if that's more) is worth a loop
MIN_APPENDIX_CHARS = MIN_APPENDIX_PAGES * PAGE_CHARS
# "Chapter 3", "Ch. 3", "3. Storage", "3: Storage", "3) Storage": a chapter, kept whole however long.
# Not "3.1 Hashing".
_CHAPTER = re.compile(r"^\s*(?:chapter\b|ch\.?\s*\d|\d+[.:)]\s)", re.IGNORECASE)
# "3 Storage" is a chapter too, but only among numbered chapters: alone, "12 Projects" is a part to open.
_NUMBERED = re.compile(r"^\s*\d+[.:)]?\s")
_SECTION = re.compile(r"^\s*\d+\.\d+")  # "6.1", "6.2 SSTables": sections of a chapter
_PART = re.compile(
    r"^\s*part\s+([ivxlc]+|\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b", re.IGNORECASE
)
MAX_EPUB_ENTRY = 50_000_000
MAX_EPUB_TOTAL = 500_000_000
MAX_EPUB_ENTRIES = 5000
IMAGE_TYPES = frozenset({".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"})
MIN_IMAGE_BYTES = 2048  # smaller is a spacer, bullet, or icon, not a figure
MAX_IMAGES_PER_CHAPTER = 80
MAX_TITLE = 200
MIN_TAIL_CHARS = 200  # text before a chapter's anchor this long is the end of the chapter before, not a label
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
# Our own placeholders: alt text and paths never hold brackets, parentheses, or spaces (matching stops early).
_IMAGE_REF = re.compile(r"!\[([^\[\]\n]*)\]\(zip:([^()\[\]\s]+)\)")


class UnsafeBookError(ValueError):
    """The file looks malicious or too large to unpack."""


def split_book(path: Path, out_dir: Path) -> list[dict]:
    """Write one file per chapter into ``out_dir`` and return chapter records.

    Raises ValueError with a message for people when the file isn't a readable PDF or EPUB.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = path.suffix.lower()
    if suffix not in (".pdf", ".epub"):
        raise ValueError("The book must be a PDF or an EPUB.")
    try:
        chapters = split_pdf(path, out_dir) if suffix == ".pdf" else split_epub(path, out_dir)
    except (UnsafeBookError, UnreadableBookError):
        raise
    except OSError:
        raise  # the disk, not the book: let the real problem show
    except Exception as error:  # any parse failure in a damaged or unusual book file
        raise UnreadableBookError(_unreadable(error)) from error
    if not chapters:  # a readable book always gives at least one chapter; this one has no pages or text
        raise UnreadableBookError(_unreadable("there's no text in it to learn from"))
    return chapters


class UnreadableBookError(ValueError):
    """The file is damaged or not really a PDF or EPUB."""


def _unreadable(error: BaseException | str) -> str:
    detail = (
        error if isinstance(error, str) else (str(error).strip().splitlines() or [type(error).__name__])[0]
    )
    return (
        f"This book couldn't be read: {detail[:160]}. "
        "Try another copy of the file (one that opens in a book reader), or a PDF of it."
    )


def is_front_matter(title: str) -> bool:
    """Pages that are never worth a learning loop, whatever their size (contents, index, glossary...)."""
    return bool(FRONT_MATTER.match(title))


def is_appendix(title: str) -> bool:
    """An appendix: a chapter when it's substantial, skipped when it's short (the splitters check size)."""
    return bool(APPENDIX.match(title))


def _median(values: list[int]) -> int:
    ordered = sorted(values)
    return ordered[len(ordered) // 2] if ordered else 0


def clean_title(title: str) -> str:
    """A title on one line, of a sensible length. Titles come from the book and end up in progress lines
    (which the app reads line by line), prompts, and files: a newline or a megabyte of text must not pass."""
    return " ".join(_CONTROL.sub(" ", title).split())[:MAX_TITLE].strip()


# ---------------------------------------------------------------- PDF


def split_pdf(path: Path, out_dir: Path) -> list[dict]:
    from pypdf import PdfReader, PdfWriter

    reader = PdfReader(str(path))
    ranges = [
        (clean_title(title) or f"Pages {first + 1}-{end}", first, end)
        for title, first, end in _pdf_chapter_ranges(reader)
    ]
    chapters = []
    for title, first, end in _pdf_keep(ranges, len(reader.pages)):
        number = len(chapters) + 1
        file = out_dir / f"{number:02d}.pdf"
        writer = PdfWriter()
        for page in range(first, end):
            writer.add_page(reader.pages[page])
        with open(file, "wb") as handle:
            writer.write(handle)
        chapters.append({"n": number, "title": title, "file": file.name, "pages": [first + 1, end]})
    return chapters


def _pdf_keep(ranges: list[tuple[str, int, int]], page_count: int) -> list[tuple[str, int, int]]:
    """The ranges worth a learning loop: no front matter, scraps, part title pages, or short appendices.
    Never nothing: when every bookmark would be skipped, the book is read as it is, or in page chunks."""
    real = [r for r in ranges if not is_front_matter(r[0]) and r[2] - r[1] >= MIN_PDF_PAGES]
    body = [end - first for title, first, end in real if not _PART.match(title) and not is_appendix(title)]
    typical = _median(body or [end - first for _, first, end in real])
    kept = []
    for i, (title, first, end) in enumerate(real):
        if is_appendix(title) and end - first < max(MIN_APPENDIX_PAGES, typical / 2):
            continue
        if _is_divider(real, i, typical):
            continue
        kept.append((title, first, end))
    return kept or real or _page_chunks(page_count)


def _is_divider(real: list[tuple[str, int, int]], i: int, typical: int) -> bool:
    """A "Part II" bookmark that's only the part's title page (and maybe a short intro): short, and followed
    by chapters before the next part, or far shorter than the book's chapters. The last one never is: a short
    final "Part 5: Exercises" is the book's own last chapter."""
    title, first, end = real[i]
    if not _PART.match(title) or end - first > MAX_DIVIDER_PAGES or i == len(real) - 1:
        return False
    return not _PART.match(real[i + 1][0]) or (end - first) * DIVIDER_SHARE <= typical


def _page_chunks(page_count: int) -> list[tuple[str, int, int]]:
    return [
        (f"Pages {p + 1}-{min(page_count, p + FALLBACK_PAGES)}", p, min(page_count, p + FALLBACK_PAGES))
        for p in range(0, page_count, FALLBACK_PAGES)
    ]


def _pdf_chapter_ranges(reader) -> list[tuple[str, int, int]]:
    """(title, first page, end page exclusive) for each chapter, from bookmarks or fixed-size chunks."""
    page_count = len(reader.pages)
    entries = _open_parts(reader, _outline_level(reader, reader.outline or []))
    real = [e for e in entries if not is_front_matter(e[0])]
    inner = [child for _, _, kids in entries for child in _outline_level(reader, kids)]
    # Still only a few top-level bookmarks ("Foundations", "Practice"), or just one (the book's own title):
    # the chapters are inside them.
    if (len(real) < 4 and len(inner) >= 4) or (len(real) <= 1 and len(inner) >= 2):
        entries = inner
    entries = _open_long_parts(reader, entries, page_count)
    first_on_page: dict[int, tuple[str, int]] = {}
    for title, page, _ in entries:
        first_on_page.setdefault(page, (title, page))  # a parent and its first child: the parent names it
    starts = sorted(first_on_page.values(), key=lambda e: e[1])
    if len(starts) < 2:
        return _page_chunks(page_count)
    ranges = []
    for i, (title, page) in enumerate(starts):
        end = starts[i + 1][1] if i + 1 < len(starts) else page_count
        ranges.append((title, page, max(page + 1, end)))
    return ranges


Entry = tuple[str, int, list]  # (title, page index, child items)


def _open_parts(reader, entries: list[Entry]) -> list[Entry]:
    """A "Part II" bookmark with chapters inside becomes those chapters, whatever else sits beside it (a
    preface, an index). Its own title page stays, ahead of its first chapter, for `_is_divider` to skip.
    A part whose bookmarks are only sections (numbered "1.2", or a few pages each in a short part) is itself
    a chapter and stays whole."""
    ordered = sorted(entries, key=lambda e: e[1])
    starts = [page for _, page, _ in ordered]
    page_count = len(reader.pages)
    ends = _next_starts(starts, page_count)
    opened: list[Entry] = []
    for (title, page, kids), end in zip(ordered, ends, strict=True):
        inside = sorted(_outline_level(reader, kids), key=lambda c: c[1]) if _PART.match(title) else []
        if len(inside) < 2 or not _holds_chapters(inside, page, end):
            opened.append((title, page, kids))
            continue
        if inside[0][1] > page:
            opened.append((title, page, []))
        opened.extend(inside)
    return opened


def _next_starts(starts: list[int], page_count: int) -> list[int]:
    """For each of the sorted start pages, the first later start past it (or the book's end), in one pass."""
    ends = [page_count] * len(starts)
    following = page_count
    for i in range(len(starts) - 1, -1, -1):
        if i + 1 < len(starts) and starts[i + 1] > starts[i]:
            following = starts[i + 1]
        ends[i] = following
    return ends


def _holds_chapters(inside: list[Entry], page: int, end: int) -> bool:
    """Whether a part's bookmarks are chapters: some are called chapters ("Chapter 3", "3. Storage"), or
    the part is long and they're chapter-sized and mostly not numbered sections ("6.1")."""
    if any(_CHAPTER.match(child) for child, _, _ in inside):
        return True
    span = max(end, max(p for _, p, _ in inside) + 1) - min(page, inside[0][1])
    return (
        span >= LONG_PART_PAGES
        and span / len(inside) >= MIN_SECTION_PAGES
        and sum(bool(_SECTION.match(child)) for child, _, _ in inside) * 2 < len(inside)
    )


def _open_long_parts(reader, entries: list[Entry], page_count: int) -> list[Entry]:
    """A bookmark far longer than the book's other chapters, whose inner bookmarks are chapter-sized
    ("Projects" holding twelve projects next to five-page chapters), becomes those chapters; its own opening
    pages stay a chapter only if there are enough of them. A chapter ("Chapter 3", or one about as long as the
    rest) stays whole, however many sections it has, and so does one whose bookmarks are numbered sections
    ("6.1", "6.2")."""
    ordered = sorted(entries, key=lambda e: e[1])
    starts = [page for _, page, _ in ordered]
    ends = _next_starts(starts, page_count)
    lengths = sorted(
        end - page
        for (title, page, _), end in zip(ordered, ends, strict=True)
        if not is_front_matter(title) and not (_PART.match(title) and end - page <= MAX_DIVIDER_PAGES)
    )
    typical = _median(lengths)
    numbered = sum(bool(_NUMBERED.match(title)) for title, _, _ in ordered if not is_front_matter(title))
    named = sum(not is_front_matter(title) for title, _, _ in ordered)
    opened: list[Entry] = []
    for (title, page, kids), end in zip(ordered, ends, strict=True):
        inside = sorted((c for c in _outline_level(reader, kids) if page <= c[1] < end), key=lambda c: c[1])
        # "6 Storage" among "5 Encoding" and "7 Replication" is a chapter; "12 Projects" among "Intro" and
        # "Setup" is a part of projects.
        chapter = _CHAPTER.match(title) or (_NUMBERED.match(title) and (numbered - 1) * 2 >= named - 1)
        if (
            not chapter
            and end - page >= max(LONG_PART_PAGES, PART_SIZE * typical)
            and len(inside) >= 2
            and (end - inside[0][1]) / len(inside) >= MIN_SECTION_PAGES
            and sum(bool(_SECTION.match(child)) for child, _, _ in inside) * 2 < len(inside)
        ):
            if inside[0][1] > page:
                opened.append((title, page, []))
            opened.extend(inside)
        else:
            opened.append((title, page, kids))
    return opened


def _outline_level(reader, items: list) -> list[tuple[str, int, list]]:
    """Bookmarks at one outline level: (title, page index, child items). Blank bookmarks mark nothing."""
    level = []
    for i, item in enumerate(items):
        if isinstance(item, list):
            continue
        children = items[i + 1] if i + 1 < len(items) and isinstance(items[i + 1], list) else []
        try:
            page = reader.get_destination_page_number(item)
            title = str(item.title).strip()
        except Exception:  # broken bookmark: skip it rather than fail the book
            continue
        if not clean_title(title):
            continue
        if isinstance(page, int) and 0 <= page < len(reader.pages):  # None or past the end: points nowhere
            level.append((title, page, children))
    return level


# ---------------------------------------------------------------- EPUB


def split_epub(path: Path, out_dir: Path) -> list[dict]:
    try:
        book = zipfile.ZipFile(str(path))
    except zipfile.BadZipFile as error:
        raise UnreadableBookError(_unreadable("it isn't a valid EPUB (zip) file")) from error
    with book:
        _check_epub_is_safe(book)
        spine, toc = _epub_spine_and_toc(book)
        documents = _Documents(book)
        starts = _toc_starts(spine, toc, documents) or [(f"Part {i + 1}", i, 0) for i in range(len(spine))]
        body = []
        for i, (title, _, _) in enumerate(starts):
            title = clean_title(title) or f"Part {i + 1}"
            text = _html_to_markdown(documents, _pieces(spine, starts, i))
            if not is_front_matter(title) and text:
                body.append((title, text))
        found = [(title, text) for title, text in body if len(text) >= MIN_EPUB_CHARS]
        if sum(len(text) for _, text in found) * 2 < sum(len(text) for _, text in body):
            found = _grouped(body)  # mostly short pieces (essays, poems): read a few at a time
        typical = _median([len(text) for title, text in found if not is_appendix(title)])
        chapters = []
        images = _Images(book, out_dir / "img")
        for title, text in found:
            if is_appendix(title) and len(text) < max(MIN_APPENDIX_CHARS, typical / 2):
                continue  # a short appendix: reference pages, not a chapter
            number = len(chapters) + 1
            file = out_dir / f"{number:02d}.md"
            text = images.save(text, number)
            file.write_text(f"# {title}\n\n{text}", encoding="utf-8")
            chapters.append({"n": number, "title": title, "file": file.name})
        return chapters


def _grouped(body: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Short neighbours joined until each group is chapter-sized ("Essay 1 and more"); a piece long enough
    on its own stays alone, and a short group left between long ones joins the group before it."""
    groups: list[list[tuple[str, str]]] = []

    def short(group: list[tuple[str, str]]) -> bool:
        return sum(len(text) for _, text in group) < MIN_EPUB_CHARS

    for title, text in body:
        if len(text) >= MIN_EPUB_CHARS and groups and short(groups[-1]) and len(groups) > 1:
            groups[-2].extend(groups.pop())  # leave no short group behind before a long piece
        if groups and short(groups[-1]):
            groups[-1].append((title, text))
        else:
            groups.append([(title, text)])
    if len(groups) > 1 and short(groups[-1]):
        groups[-2].extend(groups.pop())
    return [
        (group[0][0] if len(group) == 1 else f"{group[0][0]} and more", "\n\n".join(t for _, t in group))
        for group in groups
    ]


def _pieces(
    spine: list[str], starts: list[tuple[str, int, int]], i: int
) -> list[tuple[str, int, int | None]]:
    """(document, from offset, to offset or None for its end) that make up chapter i."""
    _, first, offset = starts[i]
    if i + 1 < len(starts):
        end, end_offset = starts[i + 1][1], starts[i + 1][2]
    else:
        end, end_offset = len(spine), 0
    if end == first:  # the next chapter starts further into the same file
        return [(spine[first], offset, end_offset)]
    pieces = [(spine[first], offset, None)]
    pieces += [(name, 0, None) for name in spine[first + 1 : end]]
    if end_offset:
        pieces.append((spine[end], 0, end_offset))
    return pieces


class _Documents:
    """The archive's XHTML files, decoded once. Missing ones read as None."""

    def __init__(self, book: zipfile.ZipFile):
        self.book, self._cache = book, {}

    def get(self, name: str) -> str | None:
        if name not in self._cache:
            try:
                self._cache[name] = _read(self.book, name)
            except KeyError:  # listed in the spine but missing from the archive
                self._cache[name] = None
        return self._cache[name]


def _check_epub_is_safe(book: zipfile.ZipFile) -> None:
    entries = book.infolist()
    if len(entries) > MAX_EPUB_ENTRIES:
        raise UnsafeBookError("This EPUB has too many files inside it.")
    total = 0
    for entry in entries:
        total += entry.file_size
        if entry.file_size > MAX_EPUB_ENTRY or total > MAX_EPUB_TOTAL:
            raise UnsafeBookError("This EPUB unpacks to something far too large.")
        if ".." in entry.filename.split("/") or entry.filename.startswith("/"):
            raise UnsafeBookError("This EPUB contains unsafe file paths.")


def _read(book: zipfile.ZipFile, name: str) -> str:
    return book.read(name).decode("utf-8", "ignore")


def _epub_spine_and_toc(book: zipfile.ZipFile) -> tuple[list[str], list[tuple[str, str, str]]]:
    try:
        container = _read(book, "META-INF/container.xml")
    except KeyError as error:
        raise UnreadableBookError(_unreadable("its META-INF/container.xml is missing")) from error
    found = re.search(r'full-path="([^"]+)"', container)
    if not found:
        raise UnreadableBookError(_unreadable("its container.xml doesn't say where the book's contents are"))
    opf_path = found.group(1)
    try:
        opf = _read(book, opf_path)
    except KeyError as error:
        raise UnreadableBookError(_unreadable(f"its package file {opf_path} is missing")) from error
    base = dirname(opf_path)
    manifest: dict[str, tuple[str, str]] = {}
    for item in re.findall(r"<item\b[^>]*>", opf):
        item_id, href = re.search(r'\bid="([^"]+)"', item), re.search(r'\bhref="([^"]+)"', item)
        if item_id and href:
            props = re.search(r'\bproperties="([^"]*)"', item)
            manifest[item_id.group(1)] = (
                normpath(join(base, unquote(href.group(1)))),
                props.group(1) if props else "",
            )
    spine = [manifest[i][0] for i in re.findall(r'<itemref\b[^<>]*idref="([^"]+)"', opf) if i in manifest]
    nav = next((href for href, props in manifest.values() if "nav" in props.split()), None)
    ncx = next((href for href, _ in manifest.values() if href.endswith(".ncx")), None)
    toc = _nav_toc(book, nav) if nav else []
    if not toc and ncx:
        toc = _ncx_toc(book, ncx)
    return spine, toc


class _TocEntry:
    """One table-of-contents entry: its title, where it points (file in the archive, or None for a heading
    without a link), the #fragment, and the entries nested under it."""

    __slots__ = ("file", "fragment", "kids", "title")

    def __init__(self, title: str = "", file: str | None = None, fragment: str = ""):
        self.title, self.file, self.fragment, self.kids = title, file, fragment, []


# Every pattern here stops at the next tag it can't belong to, and each part of the file is looked at once, so
# a hostile file can't make reading the contents take quadratic time.
_NAV_TAG = re.compile(r"<(/?)(ol|ul|li|a)\b([^<>]*)>", re.IGNORECASE)
_NCX_TAG = re.compile(r"<(/?)(navPoint|text|content)\b([^<>]*)>")
_HREF = re.compile(r"""\bhref\s*=\s*["']([^"']+)["']""")
_SRC = re.compile(r"""\bsrc\s*=\s*["']([^"']+)["']""")


def _label(markup: str) -> str:
    return " ".join(html.unescape(re.sub(r"<[^<>]*>", "", markup)).split())


def _nav_toc(book: zipfile.ZipFile, nav: str) -> list[tuple[str, str, str]]:
    text = _read(book, nav)
    start = next((tag for tag in re.finditer(r"<nav\b[^<>]*>", text) if "toc" in tag.group()), None)
    end = text.find("</nav>", start.end()) if start else -1
    if end < 0:
        return []
    return _toc_chapters(_nav_tree(text[start.end() : end], nav))


def _nav_tree(block: str, nav: str) -> list[_TocEntry]:
    """The nav's nested lists as entries. A list item's title is its link's text, or (a heading with no
    link, like "<span>Part I</span>") the text before its own nested list."""
    root: list[_TocEntry] = []
    lists = [root]  # the open lists; new items go into the innermost
    items: list[
        tuple[_TocEntry, int, int]
    ] = []  # open items: (entry, depth of its list, where its text starts)
    link: tuple[_TocEntry, int] | None = None  # a link waiting for its </a>: (entry, where its text starts)

    def close_items(depth: int, at: int) -> None:
        while items and items[-1][1] >= depth:
            entry, _, since = items.pop()
            if not entry.title and entry.file is None:
                entry.title = _label(block[since:at])

    for tag in _NAV_TAG.finditer(block):
        closing, name, attributes = tag.group(1), tag.group(2).lower(), tag.group(3)
        if name == "a":
            if link and closing:
                link[0].title = _label(block[link[1] : tag.start()])
            link = None
            href = None if closing else _HREF.search(attributes)
            if href:
                file, fragment = _target(nav, href.group(1))
                owner = items[-1][0] if items and items[-1][1] == len(lists) else None
                if owner is None or owner.file is not None or owner.title:
                    owner = _TocEntry()  # a link outside a list item, or a second link in one
                    lists[-1].append(owner)
                owner.file, owner.fragment = file, fragment
                link = (owner, tag.end())
        elif name == "li" and not closing:
            close_items(len(lists), tag.start())  # an item left open ends where the next one starts
            entry = _TocEntry()
            lists[-1].append(entry)
            items.append((entry, len(lists), tag.end()))
        elif name == "li":
            close_items(len(lists), tag.start())
        elif not closing:  # a nested list belongs to the item it's in; its heading text ends here
            owner = items[-1][0] if items and items[-1][1] == len(lists) else None
            if owner is not None and not owner.title and owner.file is None:
                owner.title = _label(block[items[-1][2] : tag.start()])
            lists.append(owner.kids if owner is not None else lists[-1])
        elif len(lists) > 1:
            close_items(len(lists), tag.start())
            lists.pop()
    return root


def _ncx_toc(book: zipfile.ZipFile, ncx: str) -> list[tuple[str, str, str]]:
    text = _read(book, ncx)
    root: list[_TocEntry] = []
    open_points: list[_TocEntry] = []
    for tag in _NCX_TAG.finditer(text):
        closing, name, attributes = tag.group(1), tag.group(2), tag.group(3)
        point = open_points[-1] if open_points else None
        if name == "navPoint" and not closing:
            entry = _TocEntry()
            (point.kids if point else root).append(entry)
            open_points.append(entry)
        elif name == "navPoint":
            if open_points:
                open_points.pop()
        elif name == "text" and not closing and point and not point.title:
            after = text.find("<", tag.end())
            point.title = _label(text[tag.end() : after if after >= 0 else len(text)])
        elif name == "content" and point and point.file is None:
            src = _SRC.search(attributes)
            if src:
                point.file, point.fragment = _target(ncx, src.group(1))
    return _toc_chapters(root)


def _toc_chapters(entries: list[_TocEntry]) -> list[tuple[str, str, str]]:
    """The entries that start chapters, (title, file, fragment) in table-of-contents order, by the same rules
    as PDF bookmarks: a single entry for the whole book, or a few groupings ("Foundations", "Practice") and
    "Part II" entries with chapters inside open into those chapters; a chapter keeps its sections inside."""
    real = [e for e in entries if not is_front_matter(e.title)]
    inner = sum(len(e.kids) for e in real)
    grouped = len(real) <= 1 or (len(real) < 4 and inner >= 4)
    top = {id(e) for e in entries}
    opened: list[_TocEntry] = []
    for entry in entries:
        opened.extend(_opened(entry, grouped) if not is_front_matter(entry.title) else [entry])
    flat: list[_TocEntry] = []
    for entry in opened:  # parts inside the book's own entry open too
        flat.extend(_opened(entry, False) if id(entry) not in top else [entry])
    return [(e.title, e.file, e.fragment) for e in flat if e.file is not None]


def _opened(entry: _TocEntry, grouped: bool) -> list[_TocEntry]:
    """The entry, or (when it holds chapters) its own opening pages followed by its chapters."""
    kids = entry.kids
    if not kids:
        return [entry]
    if entry.file is not None:
        if _CHAPTER.match(entry.title) or _sections(entry):
            return [entry]
        holds = _PART.match(entry.title) and (any(_CHAPTER.match(k.title) for k in kids) or len(kids) >= 2)
        if not holds and not (grouped and len(kids) >= 2):
            return [entry]
    first = kids[0]
    if entry.file is None or (entry.file, entry.fragment) == (first.file, first.fragment):
        return list(kids)  # nothing of its own before its first chapter: the chapter names it
    if entry.file == first.file and not entry.fragment and not first.fragment:
        return list(kids)
    return [entry, *kids]


def _sections(entry: _TocEntry) -> bool:
    """Whether the entries inside are sections of it rather than chapters: mostly numbered sections ("6.1"),
    or mostly anchors inside its own file."""
    kids = entry.kids
    numbered = sum(bool(_SECTION.match(k.title)) for k in kids)
    own_file = sum(k.file == entry.file and bool(k.fragment) for k in kids)
    return numbered * 2 > len(kids) or own_file * 2 > len(kids)


def _target(toc_file: str, href: str) -> tuple[str, str]:
    """(file in the archive, #fragment or "") a table-of-contents link points at."""
    path, fragment = urldefrag(html.unescape(href))
    return normpath(join(dirname(toc_file), unquote(path))), unquote(fragment)


def _toc_starts(
    spine: list[str], toc: list[tuple[str, str, str]], documents: _Documents
) -> list[tuple[str, int, int]]:
    """(title, spine index, offset in that file) where each table-of-contents entry begins, in reading order.

    Usually each entry is its own file (offset 0). Some books keep several chapters in one file and link to
    them by #anchor: those entries start at their anchor instead. Books split into files by size (Calibre)
    can start a chapter partway into a file: the text before its anchor ends the chapter before, unless it's
    only a label ("Chapter 3") in front of the heading.
    """
    by_file: dict[str, list[tuple[str, str]]] = {}
    for title, href, fragment in toc:
        if href in spine:
            by_file.setdefault(href, []).append((title, fragment))
    earliest = min((spine.index(href) for href in by_file), default=0)
    starts = []
    for href, entries in by_file.items():
        index = spine.index(href)
        (title, first_fragment), rest = entries[0], entries[1:]
        later = index > earliest  # a chapter before it can take the text in front of its anchor
        text = documents.get(href) if rest or (later and first_fragment) else None
        offsets = _anchor_offsets(text) if text else {}
        first = offsets.get(first_fragment, 0) if later and first_fragment else 0
        if first and len(_visible_text(text[:first])) < MIN_TAIL_CHARS:
            first = 0
        starts.append((title, index, first))  # the file's first entry takes everything before the next anchor
        seen = {first}
        for title, fragment in rest:
            offset = offsets.get(fragment) if fragment else None
            if offset and offset not in seen:
                seen.add(offset)
                starts.append((title, index, offset))
    return sorted(starts, key=lambda s: (s[1], s[2]))


_TAG = re.compile(r"<[A-Za-z][^<>]*>")
_ID = re.compile(r"""\s(?:id|name)\s*=\s*["']([^"']*)["']""")


def _anchor_offsets(text: str) -> dict[str, int]:
    """Where each element with an id (or name) begins in the file's text: the first one with it wins.
    One pass over the file, however many chapters link into it."""
    offsets: dict[str, int] = {}
    for tag in _TAG.finditer(text):
        for found in _ID.finditer(tag.group()):
            offsets.setdefault(found.group(1), tag.start())
    return offsets


class _MarkdownText(HTMLParser):
    """Collects readable text as Markdown: headings, *emphasis*, **bold**, lists, figures and captions.

    Images become `![alt](zip:path/in/archive)` placeholders; `_save_images` copies the kept ones out.
    """

    BLOCKS = frozenset({"p", "div", "br", "tr", "section", "article", "blockquote", "pre"})
    EMPHASIS: ClassVar[dict[str, str]] = {"em": "*", "i": "*", "strong": "**", "b": "**"}

    def __init__(self):
        super().__init__()
        self.parts: list[str] = []
        self.hidden_depth = 0
        self.heading: int | None = None
        self.document = ""

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "head"):
            self.hidden_depth += 1
        elif re.fullmatch(r"h[1-6]", tag):
            self.heading = int(tag[1])
            self.parts.append("\n\n" + "#" * min(3, self.heading) + " ")
        elif tag in ("img", "image"):
            values = dict(attrs)
            source = values.get("src") or values.get("xlink:href") or values.get("href") or ""
            self._image(source, values.get("alt") or "")
        elif tag == "li":
            self.parts.append("\n- ")
        elif tag == "figcaption":
            self.parts.append("\n\n*")
        elif tag in self.EMPHASIS and not self.heading:
            self.parts.append(self.EMPHASIS[tag])
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "head"):
            self.hidden_depth = max(0, self.hidden_depth - 1)
        elif re.fullmatch(r"h[1-6]", tag):
            self.parts.append("\n")
            self.heading = None
        elif tag == "figcaption":
            self.parts.append("*\n\n")
        elif tag in self.EMPHASIS and not self.heading:
            if self.parts and self.parts[-1] == self.EMPHASIS[tag]:
                self.parts.pop()  # emphasis around nothing
            else:
                self.parts.append(self.EMPHASIS[tag])
        elif tag in ("ul", "ol"):
            self.parts.append("\n\n")
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.hidden_depth:
            self.parts.append(data.replace("\n", " ") if self.heading else data)

    def _image(self, source: str, alt: str) -> None:
        if not source or source.startswith(("data:", "http:", "https:")):
            return
        path = normpath(join(dirname(self.document), unquote(urldefrag(source)[0])))
        if re.search(r"[()\[\]\s]", path):
            return  # can't be written as a Markdown image; such file names are vanishingly rare
        alt = re.sub(r"[\[\]\n]", " ", alt).strip()
        self.parts.append(f"\n\n![{alt}](zip:{path})\n\n")

    def text(self) -> str:
        joined = re.sub(r"[ \t]+", " ", "".join(self.parts))
        joined = re.sub(r"\n +", "\n", joined)
        return re.sub(r"\n{3,}", "\n\n", joined).strip()


def _visible_text(markup: str) -> str:
    """The text a reader would see in a piece of XHTML (no head, scripts, or styles), in one pass."""
    parser = _MarkdownText()
    parser.feed(markup)
    return parser.text()


def _html_to_markdown(documents: _Documents, pieces: list[tuple[str, int, int | None]]) -> str:
    parser = _MarkdownText()
    for name, start, end in pieces:
        text = documents.get(name)
        if text is None:
            continue
        parser.document = name
        parser.feed(text[start:end])
    return parser.text()


class _Images:
    """The book's figures, copied out once each: archive path -> img/NN-KK.ext, shared by every chapter that
    shows it, with a byte budget for the whole book."""

    def __init__(self, book: zipfile.ZipFile, folder: Path):
        self.book, self.folder = book, folder
        self.names = set(book.namelist())
        self.saved: dict[str, str] = {}
        self.rejected: set[str] = set()  # never read twice, however often the book points at it
        self.bytes = 0

    def save(self, text: str, number: int) -> str:
        """Point chapter ``number``'s Markdown at its real figures, copying new ones to img/NN-KK.ext; drop
        the rest. Figures past the book's budget become their alt text."""
        shown: set[str] = set()  # this chapter's figures, at most MAX_IMAGES_PER_CHAPTER
        new = 0

        def replace(match: re.Match) -> str:
            nonlocal new
            alt, path = match.group(1), match.group(2)
            suffix = Path(path).suffix.lower()
            if path in self.rejected or path not in self.names or ".." in path.split("/"):
                return ""
            if suffix not in IMAGE_TYPES:
                return ""
            if path not in shown and len(shown) >= MAX_IMAGES_PER_CHAPTER:
                return ""
            if path not in self.saved:
                # Sized up before reading: a book pointing at one huge picture again and again costs one look
                # at the archive's index, not one read each time.
                size = self.book.getinfo(path).file_size
                if size < MIN_IMAGE_BYTES:
                    self.rejected.add(path)
                    return ""
                if self.bytes + size > MAX_BOOK_IMAGE_BYTES:
                    return f"\n\n{alt}\n\n" if alt.strip() else ""
                data = self.book.read(path)
                if len(data) < MIN_IMAGE_BYTES:
                    self.rejected.add(path)
                    return ""
                if self.bytes + len(data) > MAX_BOOK_IMAGE_BYTES:
                    return f"\n\n{alt}\n\n" if alt.strip() else ""
                self.folder.mkdir(parents=True, exist_ok=True)
                new += 1
                name = f"{number:02d}-{new:02d}{suffix}"
                (self.folder / name).write_bytes(data)
                self.bytes += len(data)
                self.saved[path] = f"img/{name}"
            shown.add(path)
            return f"![{alt}]({self.saved[path]})"

        cleaned = _IMAGE_REF.sub(replace, text)
        return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


def chapter_size(chapter: dict, out_dir: Path) -> int:
    """About how many characters a chapter has: from its pages (PDF) or its Markdown text (EPUB)."""
    pages = chapter.get("pages")
    if chapter["file"].endswith(".pdf") and pages:
        return (pages[1] - pages[0] + 1) * PAGE_CHARS
    file = out_dir / "chapters" / chapter["file"]
    return len(file.read_text(encoding="utf-8")) if file.exists() else 0
