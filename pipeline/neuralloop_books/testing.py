"""Builders for small, deterministic test books, shared by every test suite."""

import zipfile
from pathlib import Path

LONG = "Systems change and engineers adapt with care. " * 50


def write_epub(
    path: Path, chapters: list[tuple[str, str]], nav: bool = True, files: dict[str, bytes] | None = None
) -> Path:
    """chapters: (title, body HTML). files: extra entries under OEBPS/, e.g. {"images/a.png": b"..."}."""
    docs = [(f"doc{i}.xhtml", title, body) for i, (title, body) in enumerate(chapters)]
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
            links = "".join(f'<li><a href="{f}">{t}</a></li>' for f, t, _ in docs)
            z.writestr(
                "OEBPS/nav.xhtml", f'<html><body><nav epub:type="toc"><ol>{links}</ol></nav></body></html>'
            )
        else:
            points = "".join(
                f'<navPoint id="p{i}"><navLabel><text>{t}</text></navLabel><content src="{f}"/></navPoint>'
                for i, (f, t, _) in enumerate(docs)
            )
            z.writestr("OEBPS/toc.ncx", f"<ncx><navMap>{points}</navMap></ncx>")
        for f, t, body in docs:
            z.writestr(
                f"OEBPS/{f}",
                f"<html><head><style>x{{}}</style></head>"
                f"<body><h1>{t}</h1><h2>Part one</h2><p>{body}</p></body></html>",
            )
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
