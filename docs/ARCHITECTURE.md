# How NeuralLoop is built

A guided tour of the whole codebase: what each directory and module is for, how a book travels from a PDF to a
learning loop on your iPad, where data lives, and how it's kept safe. Read `CLAUDE.md` for the rules of working here
and the exact contracts; this document explains the *why* and the *how it fits together*.

## The big picture

```
          you drop a book                          you study anywhere
                │                                          │
   ┌────────────▼────────────┐   Google Drive     ┌────────▼────────┐
   │  Mac app (SwiftUI)      │   app folder       │  iPad app       │
   │  ─ library, 5 steps     │◄──── sync ────────►│  (same views)   │
   │  ─ menu-bar Pip         │   books, progress, │                 │
   │  ─ runs the pipeline ───┼─┐ inbox            └─────────────────┘
   └─────────────────────────┘ │
                               ▼
   ┌──────────────────────────────────────────────────────┐
   │  Book pipeline (Python), bundled inside the Mac app  │
   │  split chapters → NotebookLM or your AI → Rumik       │
   │  voices → explainer video → book.json                 │
   └──────────────────────────────────────────────────────┘
```

Three pieces, one repo:

| Piece | Language | Where | What it does |
|---|---|---|---|
| **Book pipeline** | Python 3.10+ | `pipeline/` | Turns a PDF/EPUB into per-chapter study material and writes a book folder |
| **App core** | Swift 6 (no UI) | `apple/Sources/NeuralLoopCore` | Every rule the apps follow: spaced repetition, loops, progress merging, sync planning, Pip's animation maths. Fully unit-tested |
| **Apps** | SwiftUI | `apple/App` | The Mac app and the iPad app: screens and services (running the pipeline, Google sign-in, sync, media) |

The pipeline never talks to the apps directly. The contract between them is **files**: the pipeline writes a book
folder (`book.json`, chapters, media), and the apps read it. That's why the iPad can show books the Mac made: sync
just copies the folder.

## A book's journey

1. **You drop `Clean Code.epub` on the Mac app.** `Library.add` copies it into
   `~/Library/Application Support/app.neuralloop.books/books/clean-code/source.epub` (so the original can move, and
   macOS never asks for Documents access again) and starts the pipeline.
2. **`PipelineRunner` launches the bundled runtime**: `NeuralLoop.app/Contents/Resources/runtime/bin/neuralloop`
   (a private Python with the pipeline). Your API keys go in through environment variables from the Keychain, never
   on the command line. Output goes to the book's `pipeline.log`, so the run survives the app quitting.
3. **The pipeline splits the book** (`chapters.py`): EPUB table of contents or PDF bookmarks → `chapters/01.md`,
   `02.md`… with figures in `chapters/img/`.
4. **It makes every item for every chapter** (`pipeline.py`), chapter 1 first so you can start while it works:
   a reading guide and recall questions, a concept graph, quiz, flashcards, mind map, a podcast, and an explainer
   video. Text items and media run in separate lanes so a slow podcast never blocks a quiz.
5. **Who makes them** (`engines/`): NotebookLM first (`auto`). If NotebookLM can't (not signed in, limit reached,
   a failed item), your own AI makes that item: Ollama on your Mac by default, or Claude/OpenAI/OpenRouter/LM Studio/
   opencode/Hermes. Podcasts made locally are voiced by Rumik on your Mac.
6. **After every item it rewrites `book.json`** (`bookdata.py`), atomically. The app reads it every few seconds, so
   chapters appear as they're ready and a notification says "Chapter 1 is ready to study".
7. **Sync** (`SyncEngine`) uploads the book folder to your Drive's hidden app folder. The iPad downloads it; media
   comes down when you open a chapter.
8. **You study** on either device. Each device writes only its own progress file; everyone else's is merged in when
   read, so nothing is ever overwritten or double-counted.

## Directory by directory

```
NeuralLoop/
├── CLAUDE.md                 rules, contracts, file map (read first)
├── Makefile                  make setup / check / mac / package / runtime / pip
├── pipeline/                 the Python book pipeline
├── apple/                    the Swift core, the Mac app, the iPad app
├── scripts/                  building the runtime, packaging the DMG, dev tools
├── design/                   Pip's artwork, the app icons, the DMG window (all generated from code)
├── docs/                     specs, development guide, this document
└── .github/workflows/        CI: lint, tests, Xcode builds, stale-artwork check
```

### `pipeline/` — the book pipeline

Entry point `nl_book.py` → `neuralloop_books.cli.main()`. Everything else is the `neuralloop_books` package.

**Running a book**

| Module | What it's for |
|---|---|
| `cli.py` | Reads flags (`--engine`, `--provider`, `--media`, `--audio-length`, …) and `ai.json`, chooses the engine, runs, prints the summary. Exit codes: 0 done, 2 the book can't be read, 3 setup needed, 130 interrupted. Also the small commands the app uses: `--signin`, `--account`, `--usage`, `--check-ai`, `--grade-recall`, `--setup` |
| `pipeline.py` | The run: `prepare_state` (split or resume), an OS lock on `.running` so two runs never prepare the same book, then items in reading order across a text lane and a media lane, quota handling, and `book.json` after every item |
| `state.py` | `state.json`: every item's status (`todo`, `working`, `done`, `waiting_quota`, `failed`, `skipped`) and who made it |
| `bookdata.py` | Writes `book.json` (everything the apps show) and `knowledge-graph.json` (the book map), atomically; caches chapter text |
| `selection.py` | Parses chapter selections like `1-3,5` |
| `config.py` | Constants and copy: item names, formats, timeouts, podcast length rules |

**Reading books**

| Module | What it's for |
|---|---|
| `chapters.py` | PDF (bookmarks, parts, or 20-page chunks) and EPUB (nav/NCX table of contents, chapters split at `#anchors`) into chapter files. Safety limits against zip bombs and path tricks; unreadable books raise a friendly `UnreadableBookError` |
| `context.py` | Long chapters are condensed into notes that fit the model's budget |

**Making items**

| Module | What it's for |
|---|---|
| `engines/notebooklm.py` | Adds chapters as NotebookLM sources, then `notebook.ChapterMaker` makes each item; reopens a refused session from the saved one (other NotebookLM processes rotate Google's cookie) and retries, waiting for a podcast or video it already asked for |
| `notebook.py` | One item through notebooklm-py; recognising quota and auth errors |
| `engines/local.py` | Your own AI writes each item (checked and retried once with the reason); Rumik voices podcasts and explainers; `video.py` films explainers |
| `engines/auto.py` | NotebookLM first, the local engine for anything it can't do; records who made each item |
| `models/` | One adapter per AI: `anthropic`, `openai_compat` (OpenAI, OpenRouter, LM Studio, any compatible URL), `ollama` (with JSON schemas for small models), `opencode`, `hermes` (subprocesses, killed on timeout), `fake` (tests) |
| `speech/` | `rumik` (Rumik OSS-1 through mlx-audio, 4-bit "fast" or 8-bit "best") and `fake` |
| `prompts.py`, `schemas.py`, `convert.py` | What we ask for, the JSON shapes we require, and turning answers (from any model or NotebookLM) into our formats — tolerant of messy output |
| `video.py` | Explainer → MP4: a deterministic HTML scene rendered frame by frame in headless Chromium, encoded with PyAV |
| `audio.py` | Splitting text for speech, joining clips with pauses, converting to m4a |
| `book_graph.py` | Chapter concept graphs → one knowledge graph with links across chapters |
| `recall.py` | Grading an answer in your own words: one check per key point, evidence must come from your answer |

**Accounts and setup**: `account.py` (NotebookLM sign-in, account status, usage allowance), `aiconfig.py`
(`ai.json`: your engine, models, voices, podcast length), `setup.py` (first run: start Ollama, download models and Rumik).

**Testing helpers**: `fake_client.py` (an offline NotebookLM with the real method names), `testing.py` (builds test
books). `pipeline/tests/` has 217 tests; `conftest.py` makes sure no test can ever reach the real NotebookLM account.

### `apple/` — the Swift core and the apps

```
apple/
├── Package.swift             the NeuralLoopCore Swift package (macOS 14, iOS 17)
├── Sources/NeuralLoopCore/   pure logic, no UI
├── Tests/NeuralLoopCoreTests Swift Testing tests (swift test)
├── App/                      SwiftUI: Views/, Services/, Resources/, iPad/, NeuralLoopApp.swift
├── Config/                   Base.xcconfig (+ your Google.xcconfig, never committed)
└── project.yml               XcodeGen spec for both apps (the .xcodeproj is generated)
```

**`NeuralLoopCore`** — every decision the apps make, testable without a screen:

| File | What it's for |
|---|---|
| `Book.swift` | Decoding `book.json`: chapters, statuses, quiz, cards, mind map, graphs, media paths; the book map (`KnowledgeGraph`) |
| `Loop.swift` | The five steps and unlocking (chapter N opens when N−1's loop is closed) |
| `FSRS.swift`, `Cards.swift` | Spaced repetition (FSRS-4.5) and which cards are due |
| `Progress.swift` | `progress.json`: lenient decoding (one bad entry never loses the rest), unreadable files kept aside, merging devices (latest card review wins, a step done anywhere is done, study time adds up) |
| `Activity.swift` | The daily study log and "Your year with Pip" |
| `Remake.swift` | Remaking the mind map from memory, recall scoring, quiz progress, LaTeX → plain text |
| `GraphLayout.swift` | Where ideas sit on the concept graph (a small force layout), the book map's growth spiral, shortest paths |
| `PipRig.swift` | Playing Pip's animations: keyframes, easing, nesting transforms around pivots |
| `Nudges.swift` | When Pip may nudge you (once a day, never in quiet hours, backing off) |
| `AutoResume.swift` | When the app may start a run on its own (and when it must wait), and keeping file paths inside a book folder |
| `PrepWindow.swift` | Which chapters to prepare now, just ahead of the reader (`--chapters`, `--media`), and whether that leaves work (spec 08) |
| `Shelf.swift`, `ChapterReady.swift`, `PrepActivity.swift` | The shelf's chapter dots and cover colours; "chapter ready" (once, only for the chapter you can study next, only when complete: see docs/NOTIFICATIONS.md); the live progress feed (activity.json) as a bar and plain words |
| `RecallCheck.swift` | Word-matching and evidence rules for recall answers |
| `AIConfig.swift`, `NotebookLMUsage.swift`, `PipelineRun.swift` | `ai.json`, NotebookLM's allowance, and the pipeline's progress lines and arguments |
| `InstallPlace.swift` | Whether the app is still in Downloads or the disk image |
| `SyncPlan.swift`, `SyncEngine.swift`, `DriveStore.swift`, `GoogleOAuth.swift` | Sync (below) |

**`App/Services`** — the parts that touch the outside world:

| File | What it's for |
|---|---|
| `Library.swift` | The shelf: reads book folders off the main thread, adds books, runs and resumes the pipeline (Mac), notifications, nudges, and the iPad's inbox |
| `PipelineRunner.swift` | (Mac) Runs the bundled runtime with your keys in its environment; follows `pipeline.log`; quick commands with timeouts |
| `BookSession.swift` | One open book: its data, merged progress, the study clock |
| `MediaCenter.swift` | Shared podcast/video players (the panel and the chapter screen play the same thing) |
| `AISettings.swift`, `Keychain.swift` | (Mac) `ai.json` and your API keys in the Keychain |
| `DriveAccount.swift`, `DriveSync.swift` | Google sign-in for Drive and the sync loop |
| `Notifier.swift` | (Mac) System notifications |

**`App/Views`** — the screens: `LibraryView` (shelf, resume card, year log), `BookView` (chapters and the five
steps), `Steps` (Listen & watch, Read, Recall, Map, Remember), `StudyViews` (quiz, mind map, remake, book map),
`GraphExplorer` (the interactive concept graph), `QuickPanel` (the menu-bar panel), `SettingsView`, `ProfileButton`,
`MoveInView` (move into Applications), `LibraryDataCard` (Settings → Account's "Your library": the room it takes,
and removing every book), `PipView`, `Theme` (colours and fonts).

**`App/iPad`** — the iPad's entry point (`NeuralLoopPadApp.swift`), its settings sheet and `DriveSyncCard` (Drive
sign-in and sync, iPad only), icon, and Info.plist. The iPad app shares every view and service above; Mac-only parts
(the pipeline, the menu bar, notifications) are behind `#if os(macOS)` or left out of the iPad target in `project.yml`.

**`App/Resources`** — `pip-rig.json` and `PipLayers/` (Pip's animation data and layer pictures, generated),
`AppIcon.icns`, fonts.

### `scripts/`

| Script | What it's for |
|---|---|
| `build-runtime.sh` | Builds the private runtime the Mac app ships with: Python 3.12.14, packages installed only from hash-locked wheels (`runtime-requirements.txt`), Ollama checked by SHA-256 and Apple Team ID, Chromium for videos (downloaded by Playwright over HTTPS, then checked against a recorded SHA-256 of its installed files), and the licence texts in `runtime/licenses`. Built in a temp folder and swapped in only after every check passes |
| `package-mac.sh` | Release build → runtime inside the app → signs nested code inside out → the DMG with Pip's "move in" window → re-checks the DMG as if downloaded |
| `dev-signing-identity.sh` | One stable local signing identity so macOS remembers the app's permissions across rebuilds |
| `fake_drive.py` | A local stand-in for the Google Drive calls, for testing Mac ↔ iPad sync without a Google account (development builds only) |

### `design/`

Everything visual that's drawn with code, so it's consistent and regenerable:

- `pip/generate_pip.py` — Pip himself: every pose drawn from shared parts, every animation as data (`ANIM`). Writes the
  CSS the explainer videos use and the app's `pip-rig.json` + `PipLayers/` (layers measured and rendered in Chromium).
- `pip/make_app_icon.py`, `pip/app-icon.svg` — the Mac and iPad icons.
- `dmg/make_background.py`, `dmg/settings.py` — the disk image window ("Hi! I'm Pip. Let's move in together!").

## Where your data lives

On the Mac: `~/Library/Application Support/app.neuralloop.books/`

```
ai.json                      your engine, models, voices (never keys)
runs.json                    how each book's last run ended (for automatic retries)
sync-state.json              file hashes and inbox bookkeeping for sync
inbox/                       books added on the iPad, on their way to being prepared
books/<id>/
   source.pdf|epub           your copy of the book
   meta.json  state.json     where it came from; every item's status
   book.json                 everything the app shows
   knowledge-graph.json      the book map
   chapters/  media/  raw/   chapter text and figures; podcasts, videos; NotebookLM's raw answers
   progress.json             this device's study progress
   devices/<id>.json         other devices' progress (from sync)
   pipeline.log  .running    the run's log; the lock while it runs
```

In your Google Drive (hidden app folder, only NeuralLoop can see it): `books/<id>/…` (everything above except private
files: logs, locks, state, your source copy, other devices' downloads), `books/<id>/progress/<device>.json`, `inbox/`.

API keys: the macOS Keychain. Google Drive tokens: the Keychain (this device only). NotebookLM's session: managed by
notebooklm-py in `~/.notebooklm`.

## How sync works

- **One owner per file.** The Mac prepares books, so only the Mac uploads book files; an iPad only downloads them.
  Each device uploads only `progress/<its id>.json`. So two devices never fight over a file.
- **Merging, not overwriting.** A device shows its own progress merged with every other device's: the latest review
  of a card wins, a step done anywhere counts, study time adds up across devices (each file holds only its own time).
- **Books added on the iPad** go to `inbox/` in the Drive; the Mac downloads them, prepares them like a dropped book,
  and removes them from the inbox; the iPad then tidies its copy.
- **Media on demand.** Opening a chapter on the iPad asks for its podcast, video, and pages (and the next chapter's).
- **When.** Every two minutes while signed in, a few seconds after you study, and when a chapter opens.
- **Tested** against an in-memory Drive (every flow) and a stubbed network (every REST call), and end to end with the
  real apps through `scripts/fake_drive.py`. Real Google needs your one-time OAuth client ID (`docs/DEVELOPMENT.md`).

## How it's kept safe

- **Your books stay yours.** They're copied into the app's own folder and synced only to your own Drive, in a folder
  no other app can read. Only the chapter being prepared is sent to the AI you chose.
- **Keys never touch disk or command lines.** API keys live in the Keychain and reach the pipeline as environment
  variables; they never appear in `ai.json`, logs, or `book.json`.
- **Google sign-in** uses the system browser sheet with PKCE and a checked `state`; the app asks only for its own
  Drive folder and your email; tokens stay in the Keychain on this device.
- **Untrusted input is contained.** Book files (EPUB zips, PDFs) have size and path limits; paths from `book.json` and
  from the Drive must stay inside the library; the pipeline asks models for JSON only and validates it (model output
  is never executed or used as a path).
- **Books can't steer the AI into acting.** Models only ever return JSON that's validated. Agent-style providers are
  locked down: opencode runs with every tool permission denied, in an empty folder; Hermes runs in an empty folder and
  Settings says to turn its tools off. Error text is scrubbed of anything key-shaped before it's saved or shown.
- **Sync can't be used to reach outside the library.** Every file name coming from the Drive is checked (only
  `books/<id>/…` and strict inbox names; no `..`, backslashes, or private files), local paths must stay inside the
  library, downloads are atomic and capped at 2 GB, and the sign-in token is only ever sent to Google.
- **What ships is verified.** The runtime installs only hash-locked packages; Ollama is checked by checksum and
  signature; Chromium (fetched by Playwright, which checks no hash itself) must match a SHA-256 recorded over its
  installed files; the app runs only the runtime sealed inside its own signature.
- **Honest limits.** The Mac app isn't sandboxed (it has to run the pipeline), is ad-hoc signed (hence "Open Anyway"
  once), and runs without the hardened runtime. A Developer ID and notarization would change that
  (`docs/DEVELOPMENT.md` → "Signing").

## Building, testing, shipping

```bash
make setup     # once
make check     # every linter and test (Python and Swift)
make mac       # build and open the Mac app
make package   # dist/NeuralLoop-<version>.dmg
make pip       # regenerate Pip after changing generate_pip.py
```

The iPad app: `cd apple && xcodegen generate && open NeuralLoop.xcodeproj`, scheme **NeuralLoopPad** (see
`docs/DEVELOPMENT.md` for installing on your own iPad and the Google setup).

Rules of thumb (from `CLAUDE.md`): tests first; pure logic in `NeuralLoopCore` / `neuralloop_books`, screens thin;
generated files are never hand-edited; copy is warm and plain, and Pip is never angry or disappointed (sad
only as Silly mode's joke).
