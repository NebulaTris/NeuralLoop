# NeuralLoop Books (desktop)

Pip lives in your menu bar. Add a PDF or EPUB, and NeuralLoop prepares every chapter as a learning loop with the AI you choose (Claude, OpenAI, OpenRouter, a local Ollama model, opencode, or Google NotebookLM): listen (video + podcast), read with a guide, recall in your own words + quiz, remake the mind map from memory, and flashcards on a spaced-repetition schedule. Pip nudges you gently when cards are due or a chapter is half done.

## 1. One-time setup (the Python side)
NeuralLoop uses your Python 3.10+. Install the pipeline with the providers you want:
```bash
python3.12 -m venv ~/neuralloop-poc/.venv && source ~/neuralloop-poc/.venv/bin/activate
pip install -e "pipeline[anthropic,openai]"     # add rumik for Rumik voices, notebooklm for NotebookLM, or use [all]
```
Then pick one way to make study material:

| Choice | Set up | Run with |
|---|---|---|
| Claude | `export ANTHROPIC_API_KEY=…` | `--provider anthropic` (default model `claude-opus-5`) |
| OpenAI | `export OPENAI_API_KEY=…` | `--provider openai` |
| OpenRouter | `export OPENROUTER_API_KEY=…` | `--provider openrouter --model deepseek/deepseek-v4.1-flash` |
| Ollama (free, on your Mac) | install Ollama, `ollama pull <model>` | `--provider ollama` (uses the first installed model) |
| opencode (e.g. DeepSeek) | install opencode and sign in to your provider there | `--provider opencode --model deepseek/deepseek-v4-pro` |
| Hermes Agent | install Hermes Agent, run `hermes setup` | `--provider hermes` |
| Any OpenAI-compatible service (Nous, Together, Groq, LM Studio, vLLM…) | `export NEURALLOOP_API_KEY=…` if it needs one | `--provider custom --base-url https://…/v1 --model NAME` |
| NotebookLM | `pip install "pipeline[notebooklm]"`, then `python pipeline/nl_book.py --signin` | on by default when signed in (`--engine auto`) |

With no flags, NotebookLM is used when you're signed in; otherwise (and for any item NotebookLM can't make) the local engine
runs, with the first key it finds or Ollama. Run `python pipeline/nl_book.py --setup` once to start Ollama and download the
default model and Rumik. Voices are always Rumik OSS-1 (Apple silicon; CC-BY-NC, non-commercial use).
Bigger models write better material: small local models (around 4B) work, but take longer and need more retries.

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
- **Add a book**: pick a PDF or EPUB, choose which chapters get a podcast + video (start with `1-2`; they take the longest), pick a video style (Kawaii matches Pip). Everything else is made for every chapter.
- The book card shows live progress. **Study** opens the book's learning loop inside the app; you can start on ready chapters while the rest are still being made.
- **Prepare more** adds videos for more chapters or retries anything that hit your AI provider's limit.
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
    pipeline.py               orchestration: split, prepare the engine, make items, keep the site current
    engines/                  local (any model + speech) and notebooklm
    models/, speech/          text models (anthropic, openai, openrouter, ollama, opencode, fake) and voices (rumik, say, fake)
    audio.py, context.py      speech clips -> m4a; condensing long chapters
    schemas.py                JSON shapes that keep small local models on track
    chapters.py               PDF bookmarks / EPUB table of contents -> chapter files
    notebook.py               one item (quiz, video, ...) for one chapter via notebooklm-py
    convert.py                model and NotebookLM answers -> NeuralLoop formats (tolerant parsing)
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
