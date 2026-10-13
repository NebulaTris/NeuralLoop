# Spec 02 — Upload a PDF or EPUB, preview the chapters, parse it correctly

Status: partly done (work queue item 4) · Read first: `CLAUDE.md` · Touches: `pipeline/`, `apple/`

## Where it stands

Done:
- **Parsing real-world shapes** in `pipeline/neuralloop_books/chapters.py` (`split_book` → `split_pdf`, `split_epub`):
  bookmarks, parts that open into their chapters, the 20-page fallback, EPUB nav and NCX tables of contents read as a tree,
  chapters split at `#anchors`, short pieces grouped into chapter-sized runs, front and back matter skipped only on a whole
  title match, appendices kept when substantial, EPUB zip safety limits, and `UnreadableBookError` (the CLI exits 2 with
  "This book couldn't be read: …"). Tests in `pipeline/tests/`.
- **Adding a book**: the file picker and dropping a file on the library window (`apple/App/Views/LibraryView.swift`, with a
  "Drop your book here" overlay), and `--title` so the book keeps its name.

Still ahead: the **inspect → preview → confirm** flow below (`inspect.py`, plans, `--plan`, the "Check your chapters"
sheet) and the warnings table.

## Why

Today the app sends the book straight to the pipeline, which splits it and immediately starts NotebookLM work.
If a PDF has no bookmarks, is scanned, is encrypted, or an EPUB has an odd table of contents, the person only finds out after
spending NotebookLM quota. This spec adds an **inspect → preview → confirm** flow so people see exactly how their book was
split and can fix it before anything is generated, and it hardens the parser against the shapes real books come in.

## User experience

1. **Add a book** three ways:
   - "Add a book" button or the `+` card on the shelf (file picker, `.pdf` and `.epub`) *(done)*
   - drag a file onto the app window (the whole window shows a drop overlay: Pip hugging, "Drop your book here") *(done)*
   - drag a file onto desktop Pip (spec 01, still ahead)
   Anything else dropped shows a toast: "Pip can read PDF and EPUB books."
2. **Reading your book** sheet: Pip in the `study` pose, "Reading your book… this takes a few seconds." A Cancel button kills the
   inspect process.
3. **Check your chapters** sheet (the preview):
   - Book title (editable text input, prefilled from metadata or file name)
   - A warnings banner when there are warnings (copy in the table below), each with a one-line fix
   - One row per detected chapter: include checkbox, number, editable title, size ("pages 12–40 · 7,800 words"),
     a one-line text sample, and "Show more" to expand ~600 characters of the chapter's start
   - Row actions: **Merge with next**, **Split…** (PDF: at a page number inside the range; EPUB: at a heading from a list),
     and reorder is not allowed (reading order matters)
   - Rows the parser skipped as front/back matter appear at the bottom, unchecked, under "Skipped (cover, contents, index…)";
     people can include them
   - Footer: "N chapters will be prepared" and the existing options (media chapters, video style, podcast style, language,
     practice run), then **Start**
4. Start runs the pipeline with the confirmed plan. Everything after that is unchanged.
5. "Prepare more" on an existing book skips the preview (the plan is saved) but offers "Change chapters…" which reopens it;
   changing chapters on a book that already has materials asks for confirmation: "Chapters you changed will be prepared again."

### Warnings (code → copy → behaviour)

| Code | When | Copy | Behaviour |
|---|---|---|---|
| `ENCRYPTED` | PDF is encrypted and can't be opened without a password | "This PDF is locked. Open it in Preview, choose File → Export as PDF, and add the exported copy." | Start disabled |
| `NO_TEXT` | More than 50% of pages have fewer than 50 characters of extractable text | "This looks like a scanned book (pictures of pages), so Pip can't read the words. A text-based PDF or EPUB works best." | Start allowed (NotebookLM does OCR), warning stays |
| `NO_OUTLINE` | PDF has no usable bookmarks, so chapters are 20-page chunks | "This PDF has no chapter bookmarks, so Pip split it every 20 pages. Rename, merge, or split rows below." | Info |
| `NO_TOC` | EPUB has no nav or NCX table of contents | "This EPUB has no table of contents, so each file became a part. Merge rows to make real chapters." | Info |
| `FEW_CHAPTERS` | Fewer than 2 chapters after filtering | "Pip found only one chapter. Split it so each part is a comfortable read." | Info |
| `LONG_CHAPTER` | A chapter has more than 60 pages or 150,000 characters | "Chapter N is very long. Splitting it gives better podcasts and quizzes." | Info, row highlighted |
| `DUPLICATE_TITLES` | Two or more chapters share a title | "Some chapters share a name. Rename them so they're easy to tell apart." | Info |
| `UNSAFE_EPUB` | Zip safety limits or path traversal | "This EPUB looks damaged or unsafe, so Pip won't open it." | Start disabled |
| `UNREADABLE` | Any other parse failure | "Pip couldn't read this file. Try exporting it again, or use the other format (PDF or EPUB)." | Start disabled |

## Architecture

```
App (apple/App/Views/ImportSheets.swift) --PipelineRunner.once(["inspect", BOOK, "--json"])-->
   └ runs: nl_book.py inspect BOOK --json   ──> neuralloop_books/inspect.py → JSON on stdout
App preview edits an ImportPlan (pure functions in apple/Sources/NeuralLoopCore/ImportPlan.swift)
App (Library.add) writes <book>/plan.json atomically and passes --plan <book>/plan.json
Pipeline: chapters.split_book(path, out, plan=Plan) writes exactly the planned chapters
```

## Python changes

### New: `pipeline/neuralloop_books/inspect.py`

```python
@dataclass
class DetectedChapter:
    title: str
    kind: Literal["pdf", "epub"]
    start: int          # PDF: first page index (0-based); EPUB: first spine index
    end: int            # exclusive
    chars: int          # extracted text length
    words: int
    sample: str         # first ~600 chars of normalised text
    skipped: bool       # front/back matter or too short
    skip_reason: str | None   # "front_matter" | "too_short" | None
    headings: list[str] # EPUB: headings inside, for splitting; PDF: []

@dataclass
class Inspection:
    title: str                  # EPUB dc:title / PDF /Title metadata, else file stem
    kind: Literal["pdf", "epub"]
    pages: int | None
    chapters: list[DetectedChapter]   # reading order, skipped ones included with skipped=True
    warnings: list[dict]              # {"code": "LONG_CHAPTER", "chapter": 3} etc.

def inspect_book(path: Path) -> Inspection: ...
def to_json(inspection: Inspection) -> str: ...
```

Rules:
- Refactor `chapters.py` so detection and writing are separate: `detect_pdf_chapters(reader) -> list[DetectedChapter]` and
  `detect_epub_chapters(zip) -> list[DetectedChapter]` are used by both `inspect_book` and `split_book`. No duplicated logic.
- Text for `chars`/`words`/`sample`: PDF via `page.extract_text()` joined per range; EPUB via the existing `_MarkdownText`.
  Normalise: NFC, collapse whitespace, join hyphenated line breaks (`exam-\nple` → `example`).
- `NO_TEXT`: count pages with `< 50` extracted characters; warn when > 50% of pages.
- Encrypted PDFs: `reader.is_encrypted` → try `reader.decrypt("")` (many "encrypted" PDFs have an empty user password);
  if that fails, return an `Inspection` with no chapters and `ENCRYPTED`.
- Title metadata: PDF `reader.metadata.title` if non-empty and not "untitled"/"microsoft word - …"; EPUB `<dc:title>`.
- Performance: inspect a 600-page PDF in under 5 seconds on a laptop (text extraction is the cost; extract each page once).

### New: plans

`pipeline/neuralloop_books/plan.py`:

```python
@dataclass
class PlannedChapter:
    title: str
    start: int
    end: int   # exclusive; PDF pages or EPUB spine indices, as in DetectedChapter
    split_at_heading: str | None = None  # EPUB only: start this chapter at a heading inside the first spine document

@dataclass
class Plan:
    title: str
    chapters: list[PlannedChapter]
    version: int = 1

def load_plan(path: Path) -> Plan: ...          # validates: ranges ascending, non-overlapping, inside the book
def plan_from_inspection(i: Inspection) -> Plan: ...   # included (non-skipped) chapters, in order
```

- `chapters.split_book(path, out_dir, plan: Plan | None = None)`: with a plan, write exactly those chapters (titles from the
  plan) instead of detecting.
- `cli.py`: add a subcommand `inspect` (`nl_book.py inspect BOOK --json`, prints `to_json`; exit 0 even with warnings; exit 2
  for unreadable files with the `UNREADABLE`/`UNSAFE_EPUB`/`ENCRYPTED` JSON still printed). The existing
  `nl_book.py BOOK …` form stays the build command (backwards compatible for the app's `PipelineCommand`). Add `--plan PATH` to build.
- `pipeline.prepare_state`: when a plan is given and the saved state was made from a different plan (compare a hash of the
  plan JSON stored in `state.json` as `planHash`), re-split and **keep** finished items for chapters whose `(start, end, title)`
  didn't change; chapters that changed are reset to `todo`. Record `planHash`.

### Tests to write first (pytest, `pipeline/tests/`)

Put new builders in `neuralloop_books/testing.py` so every suite can use them.

`test_inspect.py`
- `test_pdf_with_bookmarks_reports_chapters_pages_and_samples` (use `write_pdf` extended to put real text on pages: add
  `write_text_pdf(path, pages: list[str], outline)` using `reportlab` if available, else `pypdf` + a tiny content stream; keep it
  dependency-free by writing the content stream directly)
- `test_front_matter_is_reported_as_skipped_not_dropped`
- `test_pdf_without_bookmarks_warns_no_outline_and_chunks_every_20_pages`
- `test_scanned_pdf_warns_no_text` (blank pages)
- `test_encrypted_pdf_with_empty_password_opens` and `test_encrypted_pdf_with_real_password_warns_encrypted`
  (`PdfWriter.encrypt(user_password="", owner_password="x")` / `user_password="secret"`)
- `test_parts_with_nested_chapters_use_the_chapters`
- `test_long_chapter_and_duplicate_titles_warn`
- `test_epub_nav_toc`, `test_epub_ncx_toc`, `test_epub_without_toc_warns_and_uses_spine_files`,
  `test_epub_nested_nav_uses_top_level_entries`, `test_epub_headings_listed_for_splitting`,
  `test_epub_non_utf8_documents_are_decoded` (latin-1 bytes), `test_epub_missing_spine_file_is_ignored`,
  `test_epub_zip_bomb_and_traversal_are_unsafe`
- `test_hyphenated_line_breaks_are_joined`
- `test_title_comes_from_metadata_then_file_name`
- `test_json_round_trip_matches_schema` (keys exactly as documented)

`test_plan.py`
- `test_plan_from_inspection_keeps_included_chapters_in_order`
- `test_invalid_plans_are_rejected` (overlaps, descending, out of range, empty title)
- `test_split_book_with_plan_writes_exactly_the_planned_chapters` (PDF pages and EPUB spine ranges, including `split_at_heading`)
- `test_changing_the_plan_keeps_unchanged_chapters_done_and_resets_changed_ones` (pipeline-level, FakeClient)

`test_cli.py` additions
- `test_inspect_prints_json_and_exits_0`, `test_inspect_unreadable_exits_2_with_json`, `test_build_accepts_plan`

### Real-world check (not a unit test)

Add `scripts/check_parsing.py DIR`: runs `inspect_book` on every PDF/EPUB in a folder and prints a table (file,
kind, chapters, skipped, warnings, seconds). Document it in `docs/DEVELOPMENT.md` so the owner can run it on their own library
and paste the output into an issue. Never commit books.

## App changes (Swift)

Pure logic in `NeuralLoopCore`, tested with Swift Testing in `apple/Tests` (write the tests first):

- `PipelineRun.swift`: `PipelineCommand` gains `inspectArguments(book:)` (`["inspect", BOOK, "--json"]`) and `--plan PATH`
  in `arguments(…)` when a plan is given. Tests in `PipelineRunTests.swift`: argument building, the plan flag.
- New `ImportPlan.swift` (tests in `ImportPlanTests.swift`), a `Codable`, `Sendable` model of the inspect JSON and the plan:

```swift
public struct ImportPlan: Codable, Sendable, Equatable { … }
public extension ImportPlan {
    init(inspection: Inspection)                          // included chapters, in order
    func togglingInclude(_ index: Int) -> ImportPlan
    func renaming(_ index: Int, to title: String) -> ImportPlan
    func mergingWithNext(_ index: Int) -> ImportPlan      // end = next.end, title kept, next removed
    func splittingPDF(_ index: Int, atPage page: Int) -> ImportPlan    // page strictly inside (start, end)
    func splittingEPUB(_ index: Int, atHeading heading: String) -> ImportPlan
    var problems: [String] { get }                        // [] or ["Chapter 3 needs a title", …]
}
public func describeSize(_ chapter: DetectedChapter) -> String   // "pages 12–40 · 7,800 words"
public func warningCopy(_ warning: ImportWarning) -> String      // code → the copy in the table above
public func isImportable(_ url: URL) -> Bool                     // by extension, case-insensitive
```

Thin services and views:

- `apple/App/Services/Library.swift`: `add(_:)` first runs the inspect call (`PipelineRunner.once`, 60 s timeout; Cancel
  stops it), then shows the preview; on Start it writes `<book>/plan.json` atomically, records `hasPlan: true` in
  `meta.json`, and passes `--plan`. "Prepare more" (`prepareMore`) skips the preview but offers "Change chapters…".
- New `apple/App/Views/ImportSheets.swift`: the "Reading your book" and "Check your chapters" sheets. The drop overlay and
  file picker in `LibraryView.swift` already exist and route into it; anything that isn't a PDF or EPUB shows "Pip can read
  PDF and EPUB books."
- Rows are keyboard-reachable with a visible focus ring, 44 pt minimum targets, `Theme` colours.

Swift tests (`ImportPlanTests.swift`):
- `planFromInspectionKeepsIncludedChaptersInOrder`, `mergingAndRenamingChangeThePlan`, `splitsStayInsideTheRange`
- `encryptedBookCannotStart` (an `ENCRYPTED`, `UNSAFE_EPUB`, or `UNREADABLE` warning disables Start)
- `nonBooksAreNotImportable`

## Definition of done

- All tests above written first and passing; `make check` green.
- Manually: add three books from your own library (one bookmarked PDF, one EPUB, one PDF without bookmarks); every chapter
  title and range in the preview matches the book's real table of contents, or can be fixed in the preview in under a minute.
- `python scripts/check_parsing.py ~/Books` runs without crashing on every file.
- `CLAUDE.md` "Contracts" updated with the `inspect` subcommand, `--plan`, `plan.json`, and `meta.json` `hasPlan`.
