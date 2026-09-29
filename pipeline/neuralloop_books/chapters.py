"""Split a book into chapter files. PDFs keep their pages; EPUBs become Markdown."""

import html
import re
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from posixpath import dirname, join, normpath
from typing import ClassVar
from urllib.parse import unquote, urldefrag

from .config import FRONT_MATTER

MIN_PDF_PAGES = 2
MIN_EPUB_CHARS = 1500
FALLBACK_PAGES = 20
MAX_EPUB_ENTRY = 50_000_000
MAX_EPUB_TOTAL = 500_000_000
MAX_EPUB_ENTRIES = 5000
IMAGE_TYPES = frozenset({".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"})
MIN_IMAGE_BYTES = 2048  # smaller is a spacer, bullet, or icon, not a figure
MAX_IMAGES_PER_CHAPTER = 80
_IMAGE_REF = re.compile(r"!\[([^\]]*)\]\(zip:([^)\s]+)\)")


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
    return bool(FRONT_MATTER.match(title))


# ---------------------------------------------------------------- PDF


def split_pdf(path: Path, out_dir: Path) -> list[dict]:
    from pypdf import PdfReader, PdfWriter

    reader = PdfReader(str(path))
    ranges = _pdf_chapter_ranges(reader)
    chapters = []
    for title, first, end in ranges:
        if is_front_matter(title) or end - first < MIN_PDF_PAGES:
            continue
        number = len(chapters) + 1
        file = out_dir / f"{number:02d}.pdf"
        writer = PdfWriter()
        for page in range(first, end):
            writer.add_page(reader.pages[page])
        with open(file, "wb") as handle:
            writer.write(handle)
        chapters.append({"n": number, "title": title, "file": file.name, "pages": [first + 1, end]})
    return chapters


def _pdf_chapter_ranges(reader) -> list[tuple[str, int, int]]:
    """(title, first page, end page exclusive) for each chapter, from bookmarks or fixed-size chunks."""
    page_count = len(reader.pages)
    entries = _outline_level(reader, reader.outline or [])
    real = [e for e in entries if not is_front_matter(e[0])]
    if len(real) < 4:  # books split into "Part I, Part II": use the chapters inside the parts
        inner = [child for _, _, kids in entries for child in _outline_level(reader, kids)]
        if len(inner) >= 4:
            entries = inner
    starts = sorted({page: (title, page) for title, page, _ in entries}.values(), key=lambda e: e[1])
    if len(starts) < 2:
        return [
            (f"Pages {p + 1}-{min(page_count, p + FALLBACK_PAGES)}", p, min(page_count, p + FALLBACK_PAGES))
            for p in range(0, page_count, FALLBACK_PAGES)
        ]
    ranges = []
    for i, (title, page) in enumerate(starts):
        end = starts[i + 1][1] if i + 1 < len(starts) else page_count
        ranges.append((title, page, max(page + 1, end)))
    return ranges


def _outline_level(reader, items: list) -> list[tuple[str, int, list]]:
    """Top-level bookmarks at one outline level: (title, page index, child items)."""
    level = []
    for i, item in enumerate(items):
        if isinstance(item, list):
            continue
        children = items[i + 1] if i + 1 < len(items) and isinstance(items[i + 1], list) else []
        try:
            level.append((str(item.title).strip(), reader.get_destination_page_number(item), children))
        except Exception:  # broken bookmark: skip it rather than fail the book
            continue
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
        chapters = []
        for i, (title, _, _) in enumerate(starts):
            pieces = _pieces(spine, starts, i)
            text = _html_to_markdown(documents, pieces)
            if is_front_matter(title) or len(text) < MIN_EPUB_CHARS:
                continue
            number = len(chapters) + 1
            file = out_dir / f"{number:02d}.md"
            text = _save_images(book, text, out_dir / "img", number)
            file.write_text(f"# {title}\n\n{text}", encoding="utf-8")
            chapters.append({"n": number, "title": title, "file": file.name, "chars": len(text)})
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
    spine = [manifest[i][0] for i in re.findall(r'<itemref\b[^>]*idref="([^"]+)"', opf) if i in manifest]
    nav = next((href for href, props in manifest.values() if "nav" in props.split()), None)
    ncx = next((href for href, _ in manifest.values() if href.endswith(".ncx")), None)
    toc = _nav_toc(book, nav) if nav else []
    if not toc and ncx:
        toc = _ncx_toc(book, ncx)
    return spine, toc


def _nav_toc(book: zipfile.ZipFile, nav: str) -> list[tuple[str, str, str]]:
    block = re.search(r"<nav[^>]*toc[^>]*>(.*?)</nav>", _read(book, nav), re.DOTALL)
    if not block:
        return []
    top_level = (
        re.sub(r"<ol\b[^>]*>(?:(?!<ol\b).)*?</ol>", "", block.group(1), flags=re.DOTALL)
        if block.group(1).count("<ol") > 2
        else block.group(1)
    )
    return [
        (re.sub(r"<[^>]+>", "", html.unescape(label)).strip(), *_target(nav, href))
        for href, label in re.findall(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', top_level, re.DOTALL)
    ]


def _ncx_toc(book: zipfile.ZipFile, ncx: str) -> list[tuple[str, str, str]]:
    points = re.findall(
        r"<navPoint[^>]*>\s*<navLabel>\s*<text>(.*?)</text>.*?<content[^>]*src=\"([^\"]+)\"",
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
    found = re.search(rf"""<[A-Za-z][^>]*?\s(?:id|name)\s*=\s*["']{re.escape(fragment)}["']""", text)
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


PAGE_CHARS = 2_500  # a typical book page


def chapter_size(chapter: dict, out_dir: Path) -> int:
    """About how many characters a chapter has: from its pages (PDF) or its Markdown text (EPUB)."""
    pages = chapter.get("pages")
    if chapter["file"].endswith(".pdf") and pages:
        return (pages[1] - pages[0] + 1) * PAGE_CHARS
    file = out_dir / "chapters" / chapter["file"]
    return len(file.read_text(encoding="utf-8")) if file.exists() else 0
