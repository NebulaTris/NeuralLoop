# NeuralLoop Books (desktop)

Pip lives in your menu bar. Add a PDF or EPUB, and NeuralLoop prepares every chapter as a learning loop with Google NotebookLM: listen (video + podcast), read with a guide, recall in your own words + quiz, remake the mind map from memory, and flashcards on a spaced-repetition schedule. Pip nudges you gently when cards are due or a chapter is half done.

## 1. One-time setup (the Python side)
NeuralLoop uses your Python 3.10+ with the NotebookLM library. If you followed the POC steps, you already have this in `~/neuralloop-poc/.venv`, and the app finds it automatically.
```bash
python3.12 -m venv ~/neuralloop-poc/.venv && source ~/neuralloop-poc/.venv/bin/activate
pip install "notebooklm-py[browser]" pypdf
python -m playwright install chromium
notebooklm login
```

## 2. Build and run the app on your Mac
Install [Rust](https://rustup.rs) and [Node.js 20+](https://nodejs.org), then:
```bash
cd neuralloop-books
npm install
npm run dev          # try it
npm run build        # makes NeuralLoop Books.app and a .dmg in src-tauri/target/release/bundle/
```
The first build takes a few minutes. Open the `.dmg`, drag the app to Applications. It's unsigned for now, so the first time right-click it and choose **Open**.

Notifications appear in the built app (macOS doesn't show them for `npm run dev`). Allow them when asked, or in System Settings → Notifications → NeuralLoop Books.

Windows and Linux builds: push a tag like `v0.1.0` to GitHub and the included workflow builds installers for all three systems.

## Using it
- **Add a book**: pick a PDF or EPUB, choose which chapters get a podcast + video (start with `1-2`; NotebookLM limits these per day), pick a video style (Kawaii matches Pip). Everything else is made for every chapter.
- The book card shows live progress. **Study** opens the book's learning loop inside the app; you can start on ready chapters while the rest are still being made.
- **Prepare more** adds videos for more chapters or retries anything that hit NotebookLM's daily limit.
- **Practice run** makes pretend materials without Google, to try the app.
- Closing the window keeps Pip in the menu bar so nudges keep working. Quit from the menu-bar icon.

## Nudges
At most one a day, only when there's something small worth doing (3+ cards due, or a chapter loop left halfway for 12+ hours), never during quiet hours (22:00–08:00 by default). Ignore two in a row and Pip backs off to every other day; away for a week and it's one weekly reminder. Pause until tomorrow from the menu bar.

## Where things live
Books and progress: `~/Library/Application Support/app.neuralloop.books/books/` (macOS). Each book is a folder with the chapters, media, and study site; delete a book from the app to remove it.

## For developers

### Structure
```
pipeline/                     Python package: a book in, learning loops and a study site out
  nl_book.py                  command-line entry point (the desktop app runs this)
  neuralloop_books/
    cli.py                    argument parsing and exit codes
    pipeline.py               orchestration: split, add sources, make items, keep the site current
    chapters.py               PDF bookmarks / EPUB table of contents -> chapter files
    notebook.py               one item (quiz, video, ...) for one chapter via notebooklm-py
    convert.py                NotebookLM answers -> NeuralLoop formats (tolerant parsing)
    book_graph.py             per-chapter concept graphs -> one Understand-Anything knowledge graph
    state.py                  resumable progress (state.json)
    site.py                   writes book-data.js and copies the site
    fake_client.py            offline NotebookLM stand-in for --dry-run and tests
    selection.py, prompts.py, config.py, testing.py
  site/                       the study site
    src/core/                 pure logic: fsrs, loop (steps + unlocking), cards, recall, growth, text
    src/ui/                   screens: home, chapter, stages, quiz, flashcards, mindmap, graph, bookmap
    app.js                    bundled output of src/ (npm run build), committed so Python users need no Node
  tests/                      pytest: unit tests + browser tests (tests/e2e)
src/                          desktop screens (ES modules, no build step)
  js/logic.js                 pure decisions (Pip's greeting, validation, status labels), unit-tested
  js/library.js, book.js, settings.js, state.js, tauri.js, dom.js, main.js
src-tauri/src/                desktop backend (Rust)
  pipeline.rs  library.rs  nudge.rs  server.rs  settings.rs  storage.rs  tray.rs  lib.rs (wiring)
tests/                        browser tests for the desktop screens with a simulated backend
```

### Working on it
```bash
make setup     # once: Python dev tools, Playwright + Chromium, npm packages
make test      # every test: Python, JavaScript, Rust, and browser tests
make check     # linters + formatters + tests (what CI runs)
```
The rules: pure logic lives in `core/`, `logic.js`, `convert.py`, and `nudge::decide`, with unit tests;
screens stay thin and are covered by browser tests that click through the UI the way a person would.
Write the failing test first, then the change.
