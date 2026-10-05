"""Split a book into chapter files. PDFs keep their pages; EPUBs become Markdown."""

import html
import re
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from posixpath import dirname, join, normpath
from typing import ClassVar
from urllib.parse import unquote, urldefrag

from .config import APPENDIX, FRONT_MATTER

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
        return split_pdf(path, out_dir) if suffix == ".pdf" else split_epub(path, out_dir)
    except (UnsafeBookError, UnreadableBookError):
        raise
    except OSError:
        raise  # the disk, not the book: let the real problem show
    except Exception as error:  # any parse failure in a damaged or unusual book file
        raise UnreadableBookError(_unreadable(error)) from error


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
    ends = [next((p for p in starts[i + 1 :] if p > page), page_count) for i, page in enumerate(starts)]
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
    ends = [next((p for p in starts[i + 1 :] if p > page), page_count) for i, page in enumerate(starts)]
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
        found = []
        for i, (title, _, _) in enumerate(starts):
            title = clean_title(title) or f"Part {i + 1}"
            text = _html_to_markdown(documents, _pieces(spine, starts, i))
            if not is_front_matter(title) and len(text) >= MIN_EPUB_CHARS:
                found.append((title, text))
        typical = _median([len(text) for title, text in found if not is_appendix(title)])
        chapters = []
        for title, text in found:
            if is_appendix(title) and len(text) < max(MIN_APPENDIX_CHARS, typical / 2):
                continue  # a short appendix: reference pages, not a chapter
            number = len(chapters) + 1
            file = out_dir / f"{number:02d}.md"
            text = _save_images(book, text, out_dir / "img", number)
            file.write_text(f"# {title}\n\n{text}", encoding="utf-8")
            chapters.append({"n": number, "title": title, "file": file.name})
        return chapters


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


def _nav_toc(book: zipfile.ZipFile, nav: str) -> list[tuple[str, str, str]]:
    # Every pattern here stops at the next tag it can't belong to, so a hostile file can't make matching take
    # quadratic time (a "<nav" or "<a" that never closes would otherwise be rescanned to the end each time).
    text = _read(book, nav)
    start = next((tag for tag in re.finditer(r"<nav\b[^<>]*>", text) if "toc" in tag.group()), None)
    end = text.find("</nav>", start.end()) if start else -1
    if end < 0:
        return []
    block = text[start.end() : end]
    top_level = (
        re.sub(r"<ol\b[^<>]*>(?:(?!<ol\b).)*?</ol>", "", block, flags=re.DOTALL)
        if block.count("<ol") > 2
        else block
    )
    links = []
    for attributes, label in re.findall(r"<a\b([^<>]*)>((?:(?!<a\b).)*?)</a>", top_level, re.DOTALL):
        href = re.search(r'\bhref="([^"]+)"', attributes)
        if href:
            links.append((re.sub(r"<[^>]+>", "", html.unescape(label)).strip(), *_target(nav, href.group(1))))
    return links


def _ncx_toc(book: zipfile.ZipFile, ncx: str) -> list[tuple[str, str, str]]:
    points = re.findall(
        r"<navPoint\b[^<>]*>\s*<navLabel>\s*<text>([^<]*)</text>"
        r"(?:(?!<navPoint\b).)*?<content\b[^<>]*?src=\"([^\"]+)\"",
        _read(book, ncx),
        re.DOTALL,
    )
    return [(html.unescape(label).strip(), *_target(ncx, src)) for label, src in points]


def _target(toc_file: str, href: str) -> tuple[str, str]:
    """(file in the archive, #fragment or "") a table-of-contents link points at."""
    path, fragment = urldefrag(html.unescape(href))
    return normpath(join(dirname(toc_file), unquote(path))), unquote(fragment)


def _toc_starts(
    spine: list[str], toc: list[tuple[str, str, str]], documents: _Documents
) -> list[tuple[str, int, int]]:
    """(title, spine index, offset in that file) where each table-of-contents entry begins, in reading order.

    Usually each entry is its own file (offset 0). Some books keep several chapters in one file and link to
    them by #anchor: those entries start at their anchor instead.
    """
    by_file: dict[str, list[tuple[str, str]]] = {}
    for title, href, fragment in toc:
        if href in spine:
            by_file.setdefault(href, []).append((title, fragment))
    starts = []
    for href, entries in by_file.items():
        index = spine.index(href)
        (title, _), rest = entries[0], entries[1:]
        starts.append((title, index, 0))  # the file's first entry takes everything before the next anchor
        text = documents.get(href) if rest else None
        seen = {0}
        for title, fragment in rest:
            offset = _anchor_offset(text, fragment) if text and fragment else None
            if offset and offset not in seen:
                seen.add(offset)
                starts.append((title, index, offset))
    return sorted(starts, key=lambda s: (s[1], s[2]))


def _anchor_offset(text: str, fragment: str) -> int | None:
    """Where the element with id (or name) `fragment` begins in the file's text."""
    found = re.search(rf"""<[A-Za-z][^<>]*?\s(?:id|name)\s*=\s*["']{re.escape(fragment)}["']""", text)
    return found.start() if found else None


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


def _html_to_markdown(documents: _Documents, pieces: list[tuple[str, int, int | None]]) -> str:
    parser = _MarkdownText()
    for name, start, end in pieces:
        text = documents.get(name)
        if text is None:
            continue
        parser.document = name
        parser.feed(text[start:end])
    return parser.text()


def _save_images(book: zipfile.ZipFile, text: str, folder: Path, number: int) -> str:
    """Copy the chapter's real figures to img/NN-KK.ext and point the Markdown at them; drop the rest."""
    names = set(book.namelist())
    saved: dict[str, str] = {}

    def replace(match: re.Match) -> str:
        alt, path = match.group(1), match.group(2)
        suffix = Path(path).suffix.lower()
        if path not in names or ".." in path.split("/") or suffix not in IMAGE_TYPES:
            return ""
        if path not in saved:
            data = book.read(path)
            if len(data) < MIN_IMAGE_BYTES or len(saved) >= MAX_IMAGES_PER_CHAPTER:
                return ""
            folder.mkdir(parents=True, exist_ok=True)
            name = f"{number:02d}-{len(saved) + 1:02d}{suffix}"
            (folder / name).write_bytes(data)
            saved[path] = f"img/{name}"
        return f"![{alt}]({saved[path]})"

    cleaned = _IMAGE_REF.sub(replace, text)
    return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


def chapter_size(chapter: dict, out_dir: Path) -> int:
    """About how many characters a chapter has: from its pages (PDF) or its Markdown text (EPUB)."""
    pages = chapter.get("pages")
    if chapter["file"].endswith(".pdf") and pages:
        return (pages[1] - pages[0] + 1) * PAGE_CHARS
    file = out_dir / "chapters" / chapter["file"]
    return len(file.read_text(encoding="utf-8")) if file.exists() else 0
