"""Builders for small, deterministic test books, shared by every test suite."""

import zipfile
from pathlib import Path

LONG = "Systems change and engineers adapt with care. " * 50


def write_epub(
    path: Path,
    chapters: list[tuple[str, str]],
    nav: bool = True,
    files: dict[str, bytes] | None = None,
    anchors: bool = False,
    one_file: bool = False,
) -> Path:
    """chapters: (title, body HTML). files: extra entries under OEBPS/, e.g. {"images/a.png": b"..."}.

    anchors: each chapter sits in <section id="chN"> and the table of contents links to "file#chN".
    one_file: every chapter in one XHTML file (implies anchors), the way some converters write books.
    """
    anchors = anchors or one_file
    docs = [(f"doc{i}.xhtml", title, body) for i, (title, body) in enumerate(chapters)]
    links = [
        (f"doc{0 if one_file else i}.xhtml" + (f"#ch{i}" if anchors else ""), t)
        for i, (_, t, _) in enumerate(docs)
    ]
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
            items = "".join(f'<li><a href="{href}">{t}</a></li>' for href, t in links)
            z.writestr(
                "OEBPS/nav.xhtml", f'<html><body><nav epub:type="toc"><ol>{items}</ol></nav></body></html>'
            )
        else:
            points = "".join(
                f'<navPoint id="p{i}"><navLabel><text>{t}</text></navLabel><content src="{href}"/></navPoint>'
                for i, (href, t) in enumerate(links)
            )
            z.writestr("OEBPS/toc.ncx", f"<ncx><navMap>{points}</navMap></ncx>")
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
