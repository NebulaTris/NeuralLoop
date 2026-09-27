# Spec 04 — One native Mac app (no study site, no web UI)

Status: next · Read first: `CLAUDE.md`, `docs/specs/03-pip-design-system.md` · Replaces: `src/`, `src-tauri/`, `pipeline/site/`

## Why

Today a book becomes a small website: the pipeline copies `index.html`, `app.js`, `styles.css`, and `pip-poses.js` into every
book folder, the command line opens it in a browser, and the desktop app shows it in an iframe over a private `nlbook://`
server, passing progress back with `postMessage`. The app itself is HTML and JavaScript inside Tauri.

We want one thing: a native Mac app. Everything (library, the five-step loop, quiz, flashcards, mind map, book map, settings)
opens in its own windows, built with SwiftUI. Notifications (Pip's nudges and "your book is ready") stay exactly as they are.
The Python pipeline stays; it becomes a data producer only.

## Decisions

| Topic | Decision |
|---|---|
| UI toolkit | SwiftUI (macOS 14+), with AppKit where SwiftUI has gaps (window close → hide, drag and drop, status item) |
| Platforms | macOS only. Windows and Linux support is dropped |
| Build | Swift Package Manager (works with Xcode or just the Command Line Tools); `scripts/bundle-app.sh` assembles the `.app` |
| Pipeline output | `book.json` (same payload as today's `window.BOOK`) instead of `book-data.js` + site files |
| Progress | `progress.json` only, same schema as today; the localStorage copy goes away |
| Data location | Unchanged: `~/Library/Application Support/app.neuralloop.books/` (`books/`, `settings.json`, `nudges.json`), same bundle id `app.neuralloop.books`, so existing books and progress carry over |
| Notifications | Same policy, titles and bodies, now sent with `UserNotifications`; `decide()` is ported as a pure function with the same tests |
| Menu bar | `MenuBarExtra` with the same menu; closing the window keeps Pip in the menu bar |
| Pip artwork and animation | `generate_pip.py` also writes `macos/Sources/NeuralLoop/Resources/pip-rig.json`: every pose split into ordered layers, where each animated group (`tail`, `lids`, `tilt`, `hop`, `heart`, `zz`, …) is its own SVG layer with its keyframes (the same ones the CSS uses today: rotate, scale, translate, opacity, easing, delay, alternate) and its pivot. Pivots come from the group's bounding box, measured once at generation time with Chromium's `getBBox()` (the same as CSS `transform-box: fill-box`). The app draws the layers with `NSImage` and plays the keyframes in a `TimelineView`, nesting transforms like SVG does (for example the eyelids inside the tilting head). So Pip blinks, sways, hops, turns pages, and floats hearts exactly as today, at 60 fps, and everything stops under Reduce Motion. On top of that: a springy squash-and-stretch when Pip changes pose, a happy hop on correct answers and finished steps, confetti and floating hearts as SwiftUI particles, 3D card flips, and a gentle idle so Pip never freezes (random blink offsets, an occasional ear twitch) |
| Graphs | A pure Swift force layout in the core module (seeded, deterministic, tested) replaces d3; SwiftUI `Canvas` draws it |
| Reading | PDF chapters with PDFKit; text chapters as `AttributedString` built from the chapter Markdown with reading-plan labels |
| Media | AVKit `VideoPlayer` for NotebookLM videos; `AVPlayer` for podcasts with the transcript following along; the local engine's `explainer` (spec 05) plays as an animated slideshow with Pip, one narration clip per slide. No byte-range server needed |
| AI keys | Settings → "Your AI": pick a provider (Anthropic, OpenAI, OpenRouter, Ollama, opencode, or NotebookLM), model, and speech engine (Rumik or macOS voices, with Rumik's non-commercial license note). Keys are stored in the macOS Keychain and passed to the pipeline as environment variables only |
| Tests | Swift Testing. Pure logic in `NeuralLoopCore`; each screen gets an `@Observable` model tested without UI. SwiftUI views stay thin |

## Layout

```
macos/
  Package.swift
  Sources/NeuralLoopCore/        pure, no SwiftUI or AppKit, fully unit tested
    Book.swift                   Codable model of book.json (chapters, status, quiz, cards, mindmap, graph, guide, recall)
    Progress.swift               Codable model of progress.json (cards, quiz, loop, recall, remake, mapPos, mapSeen, last)
    FSRS.swift                   grade, retrievability, formatWait            (from site/src/core/fsrs.js)
    Loop.swift                   stages, completeStage, nextStage, isUnlocked, isMapped   (loop.js)
    Cards.swift                  unlockedCards, dueCards                     (cards.js)
    Recall.swift                 recallScore, namesMatch, compareRemake      (recall.js)
    Growth.swift                 sproutPoint                                 (growth.js)
    ReaderText.swift             Markdown → reader blocks, level labels, withoutRepeatedTitle   (text.js)
    ForceLayout.swift            seeded force simulation, shortest path (graph.js logic)
    Nudge.swift                  decide, reviewedCardsDue, inQuietHours      (nudge.rs)
    Library.swift                loopsClosed, statusCounts, book summary     (library.rs)
    PipelineRun.swift            argument list, book id resolution, progress-line parsing   (pipeline.rs)
    Settings.swift               Settings with defaults, Python discovery rules   (settings.rs)
    Storage.swift                paths, atomic JSON writes, validId, slug    (storage.rs)
    Greeting.swift               pipGreeting, statusPills, setupSteps, friendlyError, isValidMediaSpec   (src/js/logic.js)
  Sources/NeuralLoop/            the app: SwiftUI views plus thin services
    NeuralLoopApp.swift          @main: WindowGroup, MenuBarExtra, Settings scene, app delegate (close → hide)
    Services/                    PipelineRunner (Process + line streaming), Notifier, NudgeScheduler, BookStore
    Models/                      @Observable screen models: LibraryModel, BookModel, LoopModel, QuizModel, ReviewModel…
    Views/Library/               shelf, setup checklist, add-book options sheet, remove confirmation
    Views/Book/                  chapter shelf, resume card, chapter loop with step bar, loop-closed celebration
    Views/Stages/                ListenAndWatch, Read, Recall, Map (with remake from memory), Remember
    Views/Study/                 Quiz, Flashcards / Review, MindMap tree, KnowledgeGraph, BookMap
    Views/Pip/                   PipView (pose + motion), toasts, confetti
    Resources/                   pip-poses.json, fonts (Fredoka, Atkinson Hyperlegible), AppIcon.icns, Info.plist
  Tests/NeuralLoopCoreTests/     one file per core file; fixtures shared with the pipeline tests
  Tests/NeuralLoopTests/         screen-model tests
scripts/bundle-app.sh            swift build -c release → NeuralLoop Books.app (Info.plist, icon, pipeline resources, ad-hoc sign)
```

## Contracts that change

- **Pipeline CLI**: `--no-open` is removed; the CLI never opens anything. The last line becomes `Book folder: PATH`.
  Progress lines (`added chapter N`, `✓ chapter N task (Xs)`, limit reached, `✗ …`) are unchanged.
- **Book folder**: `book.json` replaces `book-data.js`; `index.html`, `styles.css`, `app.js`, `pip-poses.js` are no longer
  written. Everything else (`state.json`, `meta.json`, `progress.json`, `chapters/`, `media/`, `raw/`, `knowledge-graph.json`)
  is unchanged. The app treats a book as ready when `book.json` exists. For books made before this change, it reads
  `book-data.js` once (strip `window.BOOK = … ;`) and writes `book.json`.
- **Tauri commands and events** go away. The same actions are Swift service methods, and pipeline output is an `AsyncStream`
  of lines per book.
- **CLAUDE.md**: file map, contracts, commands, golden rule 2 ("browser tests" → "screen-model tests"), and golden rule 3
  (generated files: `pip-poses.json`; `app.js` and `src-tauri/icons` go away) are updated in the final phase.

## Screens (behaviour unchanged unless noted)

1. **Library**: Pip greeting, setup checklist, book cards with status pills, progress and due cards, `+` card, add-book
   options sheet (media spec, video style, podcast style, language, dry run), retry, remove with confirmation, live progress
   while a book is prepared.
2. **Book**: chapter shelf with resume card; chapter N locked until N−1's loop is closed; live refresh as statuses change
   (driven by pipeline output, not a 10-second timer); "New study material is ready" toast.
3. **Chapter loop**: step bar for Listen & watch → Read → Recall → Map → Remember; finish buttons; loop-closed celebration
   (confetti off under Reduce Motion); `notReady` states with the pipeline's note.
4. **Quiz**, **Flashcards/Review** (FSRS, flip off under Reduce Motion), **Mind map** (collapsible tree), **Remake from
   memory**, **Knowledge graph** (pan, zoom, select a node for its panel, path between two nodes, layers), **Book map**
   (grows with each mapped chapter, remembers node positions in `mapPos`).
5. **Settings**: nudges on/off, quiet hours, pause until tomorrow, notification permission status and "Send a test nudge",
   Python path with the setup check.
6. **Menu bar**: open NeuralLoop, add a book, pause nudges today, quit.

Copy, Pip poses per situation, and accessibility rules from `CLAUDE.md` and spec 03 still apply: every control is
keyboard-reachable with a visible focus ring, VoiceOver labels on Pip and graph nodes, and AA contrast in light and dark mode.

## Phases (one or more commits each; `make check` green at the end of every phase)

1. **Package and core.** `macos/Package.swift`; port every pure module to `NeuralLoopCore`, porting the existing JS and Rust
   tests first (same cases, same expected values). The Makefile gains `swift test` (with the Command Line Tools framework
   flags when Xcode is absent).
2. **Pipeline output.** `site.py` also writes `book.json` (keep `book-data.js` until phase 6). A shared fixture book in
   `pipeline/tests/fixtures/` is decoded by both pytest and Swift tests, so the contract can't drift.
3. **App shell.** Library, add-book sheet, `PipelineRunner`, settings, menu bar, notifications and the nudge scheduler.
   `make run` builds the bundle and opens it. Test: dry-run import of the sample EPUB appears on the shelf, with its progress.
4. **Study screens.** Book, chapter loop, all five stages, quiz, review, reading (PDFKit and text), media.
5. **Maps.** Mind map, knowledge graph, book map on the Swift force layout.
6. **Switch over.** `site.py` stops copying site files and `book-data.js`; the CLI drops `--no-open`; delete `src/`,
   `src-tauri/`, `pipeline/site/`, `tests/test_desktop_ui.py`, `pipeline/tests/e2e/`, root `package.json`, Playwright from
   `make setup`; CI moves to `macos-15`; update CLAUDE.md, `docs/DEVELOPMENT.md`, and specs 01 and 02 to point at the Swift
   files (their behaviour is unchanged).

## Definition of done

- `make check` runs ruff, pytest, `swift build`, and `swift test`, and passes locally and in CI.
- `make app` produces `NeuralLoop Books.app`; opening it shows the library with existing books and progress intact.
- A dry-run import of `pipeline/sample/sample-book.epub` can be taken through a full chapter loop, a quiz, a review session,
  and the book map without any browser, iframe, or local web server.
- The "book is ready" notification and a nudge (Settings → Send a test nudge) arrive as system notifications as before.
- `grep -r "window.BOOK\|nlbook://\|__TAURI__" --include=*.swift --include=*.py .` finds nothing outside the one-time
  migration of old `book-data.js` files.
