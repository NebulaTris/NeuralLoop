# Spec 04 — One native app for Mac and iPad (no study site, no web UI)

Status: done (built) · Read first: `CLAUDE.md`, `docs/specs/03-pip-design-system.md`

The SwiftUI app shipped and replaced the Tauri app and the per-book study site, which are gone from the repo. This spec is
kept as the record of why and what was decided. Where it differs from what was built, `CLAUDE.md` wins: the code lives in
`apple/` (`Sources/NeuralLoopCore`, `App/`, `project.yml` for XcodeGen), `make mac` builds and opens the app, `make package`
makes the DMG, and the recall check on the Mac runs through the pipeline (`--grade-recall`). Still ahead from this spec:
a first-launch setup screen, and laptops other than Macs.

## Why

Before this spec, a book became a small website: the pipeline copied `index.html`, `app.js`, `styles.css`, and
`pip-poses.js` into every book folder, the command line opened it in a browser, and the desktop app showed it in an iframe
over a private `nlbook://` server, passing progress back with `postMessage`. The app itself was HTML and JavaScript inside
Tauri.

We want one thing: a native Mac app. Everything (library, the five-step loop, quiz, flashcards, mind map, book map, settings)
opens in its own windows, built with SwiftUI. Notifications (Pip's nudges and "your book is ready") stay exactly as they are.
The Python pipeline stays; it becomes a data producer only.

## Decisions

| Topic | Decision |
|---|---|
| UI toolkit | SwiftUI multiplatform: macOS 14+ and iPadOS 17+ from one codebase (owner's decision), with AppKit/UIKit where SwiftUI has gaps. Mac-only: pipeline, menu bar, desktop Pip. The library follows the Google account across devices (spec 07) |
| Platforms | Mac and iPad first (personal use). Windows and Linux later with their own app on the same account, library, and book format |
| Build | Swift Package Manager for `NeuralLoopCore` and its tests (works with just the Command Line Tools); the app targets need Xcode (required by Apple for iPad builds) |
| Pipeline output | `book.json` (same payload as today's `window.BOOK`) instead of `book-data.js` + site files |
| Progress | `progress.json` only, same schema as today; the localStorage copy goes away |
| Data location | Unchanged: `~/Library/Application Support/app.neuralloop.books/` (`books/`, `settings.json`, `nudges.json`), same bundle id `app.neuralloop.books`, so existing books and progress carry over |
| Notifications | Same policy, titles and bodies, now sent with `UserNotifications`; `decide()` is ported as a pure function with the same tests |
| Menu bar | `MenuBarExtra` with the same menu; closing the window keeps Pip in the menu bar |
| Pip artwork and animation | `generate_pip.py` also writes `apple/App/Resources/pip-rig.json`: every pose split into ordered layers, where each animated group (`tail`, `lids`, `tilt`, `hop`, `heart`, `zz`, …) is its own SVG layer with its keyframes (the same ones the CSS uses today: rotate, scale, translate, opacity, easing, delay, alternate) and its pivot. Pivots come from the group's bounding box, measured once at generation time with Chromium's `getBBox()` (the same as CSS `transform-box: fill-box`). The app draws the layers with `NSImage` and plays the keyframes in a `TimelineView`, nesting transforms like SVG does (for example the eyelids inside the tilting head). So Pip blinks, sways, hops, turns pages, and floats hearts exactly as today, at 60 fps, and everything stops under Reduce Motion. On top of that: a springy squash-and-stretch when Pip changes pose, a happy hop on correct answers and finished steps, confetti and floating hearts as SwiftUI particles, 3D card flips, and a gentle idle so Pip never freezes (random blink offsets, an occasional ear twitch) |
| Graphs | A pure Swift force layout in the core module (seeded, deterministic, tested) replaces d3; SwiftUI `Canvas` draws it |
| Reading | PDF chapters with PDFKit; text chapters as `AttributedString` built from the chapter Markdown with reading-plan labels |
| Media | AVKit `VideoPlayer` for NotebookLM videos; `AVPlayer` for podcasts with the transcript following along; the local engine's `explainer` (spec 05) plays as an animated slideshow with Pip, one narration clip per slide. No byte-range server needed |
| First launch | Welcome screen: **Sign in with Google** (runs `neuralloop --signin`: a real Chrome window; the same session is NotebookLM's, and the account's email shows in the app) or **Not now** (Pip uses Ollama). Then a friendly setup screen shows `neuralloop --setup` progress (`  setup: …` lines) while Ollama starts and the local model, the recall model, and Rumik download once |
| Runtime | The app bundle carries `Contents/Resources/runtime` from `scripts/build-runtime.sh` (Python, pipeline, every provider, Rumik, NotebookLM, Ollama); every pipeline call goes through `runtime/bin/neuralloop`. Nothing else to install |
| Recall | Checked on the device by a small open-source model through MLX Swift (same per-key-point, evidence-grounded rules as `pipeline/neuralloop_books/recall.py`, ported to `NeuralLoopCore`), so it's instant and works offline on the iPad; word matching as the fallback |
| Reader | Text chapters read like a textbook: figures from `chapters/img/` with captions, emphasis, lists, reading-plan labels; PDF chapters show the original pages in PDFKit |
| AI keys | Settings → "Your AI": pick a provider (Anthropic, OpenAI, OpenRouter, Ollama, opencode, or NotebookLM), model, optional per-item models, the recall model (default `gemma2:2b`), and Rumik's two voices, written to the person's `ai.json`; Rumik's non-commercial license note shown. Keys are stored in the macOS Keychain and passed to the pipeline as environment variables only |
| Tests | Swift Testing. Pure logic in `NeuralLoopCore`; each screen gets an `@Observable` model tested without UI. SwiftUI views stay thin |

## Layout

See `CLAUDE.md`'s file map for the real layout (`apple/Sources/NeuralLoopCore`, `apple/App/Views`, `apple/App/Services`,
`apple/App/iPad`, `apple/Tests`).

## Contracts that change

- **Pipeline CLI**: the CLI never opens anything (`--no-open` is kept and does nothing). The last line is `Book: DIR`.
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

## Phases

All six phases are done: the core package and its tests, `book.json` from the pipeline, the app shell, the study screens,
the maps, and the switch-over that removed the web UI. `--no-open` stayed as a flag that does nothing, for older callers.

## Definition of done

- `make check` runs ruff, pytest, `swift build`, and `swift test`, and passes locally and in CI.
- `make mac` builds and opens `NeuralLoop.app`; opening it shows the library with existing books and progress intact.
- A dry-run import of `pipeline/sample/sample-book.epub` can be taken through a full chapter loop, a quiz, a review session,
  and the book map without any browser, iframe, or local web server.
- The "book is ready" notification and a nudge (Settings → Send a test nudge) arrive as system notifications as before.
- `grep -r "window.BOOK\|nlbook://\|__TAURI__" --include=*.swift --include=*.py .` finds nothing outside the one-time
  migration of old `book-data.js` files.
