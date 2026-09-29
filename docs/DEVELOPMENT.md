# NeuralLoop (Mac)

Pip lives in your menu bar. Drop a PDF or EPUB on NeuralLoop and every chapter becomes a learning loop: listen (video +
podcast), read with a guide, recall in your own words and take a quiz, remake the mind map from memory and explore the
concept graph, then flashcards on a spaced-repetition schedule. The book map grows with every chapter you map. NotebookLM
makes everything by default; your own AI takes over whenever NotebookLM can't (or all the time, if you choose).

## Install

Download `NeuralLoop-<version>.dmg`, drag NeuralLoop to Applications, and open it. It isn't signed by Apple yet, so the first
time macOS asks: open System Settings → Privacy & Security and choose **Open Anyway**. Everything it needs is inside the app
(Python, every AI provider, Rumik's voices, NotebookLM, Chromium for videos, and Ollama); the local models download the first
time they're needed.

## Using it

- **Add a book**: drop it on the window or choose Add a book. Pip makes a podcast and video for chapters 1–2 and everything
  else for every chapter; **Prepare more** adds media for every chapter and retries anything that needs another go.
- **Settings** (⌘,): sign in with Google for NotebookLM, pick your AI and keys (kept in the Keychain), voices and podcast
  length, and nudges (at most one a day, never in quiet hours, backing off if you skip them).
- **Menu bar**: pick up where you left off, play the chapter's podcast and video, review due cards, see NotebookLM's allowance.
- Books and progress live in `~/Library/Application Support/app.neuralloop.books/books/`.

## For developers

```bash
make setup     # once: Python dev tools, Playwright + Chromium (for explainer videos)
make check     # linters + every test (Python and Swift)
make mac       # build and open the app (Xcode + XcodeGen: brew install xcodegen)
make package   # dist/NeuralLoop-<version>.dmg
```

- `pipeline/` — the Python pipeline (a book in, `book.json` out); see its README and `CLAUDE.md` for the file map.
- `apple/Sources/NeuralLoopCore` — the app's pure logic with Swift tests; `apple/App` — SwiftUI views and services.
- `scripts/` — the runtime build (hash-locked packages, checksummed Ollama) and packaging.

The rules: pure logic lives in `NeuralLoopCore` and `neuralloop_books`, with tests; screens stay thin. Write the failing test
first, then the change. `CLAUDE.md` has the contracts between the app and the pipeline.
