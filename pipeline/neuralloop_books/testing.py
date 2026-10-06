"""Builders for small, deterministic test books, shared by every test suite."""

import zipfile
from pathlib import Path

LONG = "Systems change and engineers adapt with care. " * 50
TocEntry = tuple[str, "int | str | None", list]  # (title, target, children): see write_epub


def write_epub(
    path: Path,
    chapters: list[tuple[str, str]],
    nav: bool = True,
    files: dict[str, bytes] | None = None,
    anchors: bool = False,
    one_file: bool = False,
    toc: list[TocEntry] | None = None,
) -> Path:
    """chapters: (title, body HTML). files: extra entries under OEBPS/, e.g. {"images/a.png": b"..."}.

    anchors: each chapter sits in <section id="chN"> and the table of contents links to "file#chN".
    one_file: every chapter in one XHTML file (implies anchors), the way some converters write books.
    toc: a nested table of contents instead of one entry per chapter: (title, target, children), where the
    target is a chapter's index, an href ("doc2.xhtml#s1"), or None for a heading without a link (nav only).
    """
    anchors = anchors or one_file
    docs = [(f"doc{i}.xhtml", title, body) for i, (title, body) in enumerate(chapters)]
    entries: list[TocEntry] = toc if toc is not None else [(t, i, []) for i, (_, t, _) in enumerate(docs)]
    if one_file:
        docs = docs[:1]
    manifest = "".join(
        f'<item id="d{i}" href="{f}" media-type="application/xhtml+xml"/>' for i, (f, _, _) in enumerate(docs)
    )
    if nav:
        manifest += '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    else:
        manifest += '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    spine = "".join(f'<itemref idref="d{i}"/>' for i in range(len(docs)))

    def href_of(target: int | str | None) -> str | None:
        if target is None or isinstance(target, str):
            return target
        return f"doc{0 if one_file else target}.xhtml" + (f"#ch{target}" if anchors else "")

    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr(
            "META-INF/container.xml",
            '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
        )
        z.writestr(
            "OEBPS/content.opf", f"<package><manifest>{manifest}</manifest><spine>{spine}</spine></package>"
        )
        if nav:
            items = _nav_items(entries, href_of)
            z.writestr(
                "OEBPS/nav.xhtml", f'<html><body><nav epub:type="toc"><ol>{items}</ol></nav></body></html>'
            )
        else:
            z.writestr("OEBPS/toc.ncx", f"<ncx><navMap>{_nav_points(entries, href_of)}</navMap></ncx>")
        sections = [
            (f'<section id="ch{i}">' if anchors else "")
            + f"<h1>{t}</h1><h2>Part one</h2><p>{body}</p>"
            + ("</section>" if anchors else "")
            for i, (t, body) in enumerate(chapters)
        ]
        bodies = ["".join(sections)] if one_file else sections
        for (f, _, _), body in zip(docs, bodies, strict=True):
            z.writestr(f"OEBPS/{f}", f"<html><head><style>x{{}}</style></head><body>{body}</body></html>")
        for name, data in (files or {}).items():
            z.writestr(f"OEBPS/{name}", data)
    return path


def _nav_items(entries: list[TocEntry], href_of) -> str:
    html = ""
    for title, target, children in entries:
        href = href_of(target)
        label = f'<a href="{href}">{title}</a>' if href else f"<span>{title}</span>"
        inner = f"\n<ol>{_nav_items(children, href_of)}</ol>" if children else ""
        html += f"\n<li>{label}{inner}</li>"
    return html


def _nav_points(entries: list[TocEntry], href_of) -> str:
    return "".join(
        f"<navPoint><navLabel><text>{title}</text></navLabel>"
        + (f'<content src="{href_of(target)}"/>' if target is not None else "")
        + _nav_points(children, href_of)
        + "</navPoint>"
        for title, target, children in entries
    )


def write_pdf(path: Path, pages: int, outline: list[tuple[str, int, list[tuple[str, int]]]]) -> Path:
    """outline entries: (title, page index, [(child title, child page index)])."""
    from pypdf import PdfWriter

    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=300, height=400)
    for title, page, children in outline:
        parent = writer.add_outline_item(title, page)
        for child_title, child_page in children:
            writer.add_outline_item(child_title, child_page, parent=parent)
    with open(path, "wb") as handle:
        writer.write(handle)
    return path
