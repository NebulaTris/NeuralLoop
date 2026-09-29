# CLAUDE.md — working in the NeuralLoop repo

Read this first, every session. Specs for new work live in `docs/specs`. The long-term vision is `docs/vision/BUILD_SPEC.md`
(where it disagrees with this file or the specs, **this file and `docs/specs` win**; notably the repo license is **MIT**).

## What this repo is

NeuralLoop is an out-of-the-box learning tool for developers. It turns a book the user owns (PDF or EPUB) into five-step
learning loops per chapter, made with any AI model the user
plugs in (Anthropic, OpenAI, OpenRouter, local Ollama, opencode) or, optionally, Google NotebookLM:
**Listen & watch → Read → Recall → Map → Remember**. Chapters unlock one at a time; the book map grows as chapters are mapped.
Pip, a cute red panda, lives in the menu bar and nudges gently (never guilt).

Three parts, one repo:

| Part | Language | Path | Runs as |
|---|---|---|---|
| Book pipeline | Python 3.10+ | `pipeline` | `python pipeline/nl_book.py BOOK …` (the desktop app spawns this) |
| Study site | JavaScript (ES modules, bundled) | `pipeline/site` | static files copied into each book folder |
| Desktop app | Rust (Tauri 2) + JavaScript | `src-tauri`, `src` | `NeuralLoop Books.app` |

## Golden rules

1. **Test first.** Write the failing test, watch it fail, make it pass, refactor. Every task in `docs/specs` lists its tests.
2. **Logic stays pure and tested; screens stay thin.** Pure logic belongs in `pipeline/neuralloop_books/*.py`,
   `pipeline/site/src/core/*.js`, `src/js/logic.js` (or a new pure module next to it), and pure Rust functions like
   `nudge::decide`. Screens (`pipeline/site/src/ui/*`, `src/js/*` other than logic) only render and wire events; cover them
   with browser tests that click the real UI.
3. **Never hand-edit generated files:**
   `pipeline/site/app.js` (run `npm run build` in `pipeline/site`), `pipeline/site/pip-poses.js` and `src/pip-poses.js`
   (run `python design/pip/generate_pip.py`), `src-tauri/icons/*` (run `npx tauri icon design/pip/app-icon.png`).
4. **`make check` must pass before every commit.** It runs formatters, linters, and all tests.
5. **Small commits** with imperative messages (`Add book import preview`, `Fix EPUB nav with nested lists`).
6. **Respect contracts** (section "Contracts" below). If you change one, update this file and the tests in the same commit.
7. **No secrets, no user books, no generated media in git.** `.gitignore` covers `node_modules/`, `target/`, `gen/`,
   and book output folders (`neuralloop-*/`).
8. **Copy for people is warm and plain.** Sentence case, no guilt ("You missed…" is never OK), errors say what happened and how
   to fix it. Pip is never sad, angry, or disappointed.

## Setup and commands

```bash
make setup      # once: pip install -e "pipeline[dev]" + playwright + chromium, npm install (root and pipeline/site)
make test       # all tests
make lint       # ruff, prettier --check, cargo fmt --check, clippy -D warnings
make check      # lint + test (CI runs this: .github/workflows/check.yml)
make site       # rebuild pipeline/site/app.js from pipeline/site/src
npm run dev     # run the desktop app with hot reload (needs Rust: https://rustup.rs)
npm run build   # build the .app/.dmg into src-tauri/target/release/bundle/
python pipeline/nl_book.py --dry-run --out /tmp/demo   # whole pipeline offline with a practice model and voices
```

Per part: `cd pipeline && pytest -q` · `cd pipeline/site && npm test` · `cd src && npm test` ·
`PYTHONPATH=pipeline pytest -q tests` (desktop browser tests) · `cd src-tauri && cargo test --lib`.

The user's Python lives at `~/neuralloop-poc/.venv/bin/python` (3.12, has `notebooklm-py`); the app finds it automatically.
For development, a Python 3.12 venv at `.venv` works: `make setup PY=$PWD/.venv/bin/python`.

## File map

### `pipeline` — Python package `neuralloop_books`
| File | Responsibility |
|---|---|
| `nl_book.py` | Entry point; friendly exit on Python < 3.10; calls `cli.main()` |
| `neuralloop_books/cli.py` | Argument parsing, engine choice, exit codes (0 ok, 2 invalid input, 3 setup needed: key, model, Ollama, sign-in; 130 interrupted), final summary |
| `neuralloop_books/pipeline.py` | `Options`, `prepare_state` (split or resume, apply selection), `run(opts, engine)` (prepare the engine, make items in a text lane and a media lane, quota handling, rebuild site after every item) |
| `neuralloop_books/chapters.py` | `split_book` → `split_pdf` (bookmarks, parts, 20-page fallback) and `split_epub` (nav/NCX TOC, safety limits); front-matter filter |
| `neuralloop_books/engines/local.py` | `LocalEngine`: any text model writes each item (checked, retried once with the reason); podcasts and explainers voiced by a speech engine |
| `neuralloop_books/engines/notebooklm.py` | `NotebookLMEngine`: adds chapters as sources, then `ChapterMaker` makes each item |
| `neuralloop_books/notebook.py` | `ChapterMaker.make(task, chapter)`: one item via notebooklm-py; `is_quota_error`; `open_client` |
| `neuralloop_books/models/` | Text models: `make_model(provider, model)`, `SetupError`, `QuotaError`; `anthropic`, `openai_compat` (OpenAI, OpenRouter, any compatible `custom` URL), `hermes` (Hermes Agent one-shot), `ollama` (native API, JSON schemas), `opencode` (subprocess), `fake` |
| `neuralloop_books/speech/` | Speech: `make_speech(name, voices)`; `rumik` (Rumik OSS-1 via mlx-audio, 8-bit or 4-bit by memory; CC-BY-NC) is the only voice; `fake` for tests |
| `neuralloop_books/engines/auto.py` | `AutoEngine`: NotebookLM first, local engine for the whole run or per failed item; results tagged with who made them (`tasks.*.by`) |
| `neuralloop_books/video.py` | Explainer → MP4: deterministic HTML/JS scene (`renderAt(t)`), frames from headless Chromium, PyAV x264 + narration; fills `chapter.video` (`NEURALLOOP_VIDEO=0` turns it off) |
| `neuralloop_books/recall.py` | `grade(model, question, keyPoints, answer)`: one check per key point in parallel, evidence must be in the answer and about the idea; `word_match` fallback |
| `neuralloop_books/aiconfig.py` | `load(path)` → `AIConfig` (engine, make, per-item `tasks`, recall model, voices) from the person's `ai.json` |
| `neuralloop_books/setup.py` | First run: `ensure_ollama` (bundled or installed), `ensure_model` (default by memory: `qwen3:8b`/`qwen3:4b`), `ensure_rumik` |
| `neuralloop_books/account.py` | Google sign-in via `notebooklm login` (Chrome when installed) and `status()` via `notebooklm auth check --json` |
| `neuralloop_books/audio.py` | `split_for_speech`, `join_wavs` (with pauses, returns durations), `to_m4a` (afconvert) |
| `neuralloop_books/context.py` | `chunks`, `source_for`: long chapters are condensed into notes that fit the model's budget |
| `neuralloop_books/schemas.py` | JSON schemas per item; Ollama uses them to constrain small models |
| `neuralloop_books/convert.py` | Model and NotebookLM outputs → our formats: `loose_json`, `quiz`, `flashcards`, `study`, `concept_graph`, `mind_map`, `podcast_script`, `explainer` |
| `neuralloop_books/book_graph.py` | Chapter graphs → one Understand-Anything knowledge graph; `similar_to` links across chapters |
| `neuralloop_books/state.py` | `BookState` (state.json): statuses, `apply_selection`, `pending` (reading order: chapter 1 first), `counts` |
| `neuralloop_books/site.py` | Writes `book-data.js`, `knowledge-graph.json`, copies `site/{index.html,styles.css,app.js,pip-poses.js}` |
| `neuralloop_books/fake_client.py` | Offline NotebookLM with identical method names (`FakeClient`, `FakeQuotaClient`, `ENUMS`) |
| `neuralloop_books/selection.py` | `parse_selection("1-3,5", n)` |
| `neuralloop_books/prompts.py` | NotebookLM chat prompts and the local engine's prompts (sent verbatim; long lines allowed) |
| `neuralloop_books/config.py` | Task names, format/style enums, front-matter regex, timeouts, copy |
| `neuralloop_books/testing.py` | `write_epub`, `write_pdf`, `LONG`: builders for test books, shared by all suites |
| `tests` | Unit tests; `tests/e2e/test_study_site.py` drives the study site in Chromium |
| `sample/sample-book.epub` | Bundled sample for dry runs |

### `pipeline/site` — the study site (one per book)
| File | Responsibility |
|---|---|
| `index.html`, `styles.css` | Page shell and styles (tokens at the top of `styles.css`) |
| `src/main.js` | Routing, header nav, live refresh of `book-data.js` while the pipeline runs |
| `src/core/fsrs.js` | FSRS-4.5 `grade`, `retrievability`, `formatWait` |
| `src/core/loop.js` | `STAGES`, `completeStage`, `nextStage`, `isUnlocked` (chapter N needs N−1 closed), `isMapped` |
| `src/core/cards.js` | `unlockedCards`, `dueCards` |
| `src/core/recall.js` | `recallScore`, `namesMatch`, `compareRemake` (remake the mind map from memory) |
| `src/core/growth.js` | `sproutPoint` (golden-angle spiral for the growing book map) |
| `src/core/text.js` | `escapeHtml`, `markdownToHtml` (figures, captions, emphasis, lists, reading-plan labels), `withoutRepeatedTitle`, `madeWith` |
| `src/core/activity.js` | `logActivity`, `yearGrid` (53 weeks, Sunday first), `yearStats` (only encouraging totals), `studyLevel`, `formatDuration` |
| `src/ui/context.js` | `book`, `store` (localStorage + `postMessage` to the desktop app), `route`, `go` |
| `src/ui/yearlog.js` | "Your year with Pip": study-time heatmap with hover, keyboard reading, and a table view |
| `src/ui/home.js`, `chapter.js`, `stages.js`, `quiz.js`, `flashcards.js`, `mindmap.js`, `graph.js`, `bookmap.js` | Screens |
| `src/ui/dom.js` | `$`, `pip(pose)`, `toast`, `confetti`, `notReady`, icons, status labels |
| `test/core.test.mjs` | Unit tests for `src/core` (`npm test`) |

### `src` — desktop app screens (ES modules, no build step)
| File | Responsibility |
|---|---|
| `index.html`, `styles.css`, `fonts/` | Shell, styles, bundled fonts (Fredoka, Atkinson Hyperlegible) |
| `js/main.js` | Entry: navigation, backend events (`pipeline`, `menu-add-book`, `toast`, `nudge`) |
| `js/logic.js` | Pure: `isValidMediaSpec`, `pipGreeting`, `statusPills`, `setupSteps`, `friendlyError` |
| `js/library.js` | Shelf, setup checklist, add-book options sheet, remove |
| `js/book.js` | Study site in an iframe via `nlbook://`; saves progress messages |
| `js/settings.js` | Nudges, quiet hours, Python path |
| `js/state.js`, `js/tauri.js`, `js/dom.js` | Shared state, Tauri API wrapper (`invoke`, `listen`, `pickFile`, `BOOKS_BASE`), DOM helpers |
| `test/logic.test.mjs` | Unit tests (`cd src && npm test`) |

### `src-tauri/src` — desktop backend (Rust)
| File | Responsibility |
|---|---|
| `lib.rs` | Wiring only: plugins, `nlbook` scheme, commands, window close → hide, nudge loop |
| `pipeline.rs` | `start_pipeline`, `cancel_pipeline`, `Jobs`; streams stdout as `pipeline` events; notifies when a book is ready |
| `library.rs` | `list_books`, `delete_book`, `save_progress`; `loops_closed`, `status_counts` |
| `nudge.rs` | Pure `decide()` (one a day, quiet hours, back-off) + `tick`, `nudge_engaged`, `pause_until_tomorrow` |
| `server.rs` | `nlbook://` file server with byte ranges (video seeking on macOS), traversal protection |
| `settings.rs` | `Settings` (settings.json), `find_python`, `check_setup` |
| `storage.rs` | Paths, atomic JSON writes, `valid_id`, `slug`, `now_ms` |
| `tray.rs` | Menu-bar/tray icon and menu |
| `../tauri.conf.json`, `../capabilities/default.json` | Windows, CSP, bundle resources, permissions |

### Other
`scripts/build-runtime.sh` (self-contained runtime: relocatable Python + pipeline + every provider + Rumik + NotebookLM +
Ollama, launched by `runtime/bin/neuralloop`; `make runtime`) · `scripts/dev-signing-identity.sh` (one stable self-signed identity so macOS remembers the app's
permissions across rebuilds; `make mac` uses it) · `design/pip/generate_pip.py` (Pip artwork source) · `design/pip/app-icon.svg` · `experiments/notebooklm` (POCs, not shipped) ·
`tests/test_desktop_ui.py` (desktop screens in Chromium with a simulated backend) · `docs/DEVELOPMENT.md` · `Makefile`.

## Contracts

- **Pipeline CLI** (used by `src-tauri/src/pipeline.rs`): `nl_book.py BOOK --out DIR --no-open --media SPEC --style S --audio A
  --video V --language L [--engine auto|local|notebooklm] [--provider auto|anthropic|openai|openrouter|custom|ollama|opencode|hermes|fake]
  [--model M] [--base-url URL] [--context CHARS] [--speech auto|rumik|fake] [--voices A,B] [--dry-run] [--retry]`.
  `auto` (default) = NotebookLM when signed in, the local engine (Ollama unless a key is set) for the whole run when not, and
  per item when NotebookLM fails or hits its limit. Keys only from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
  `NEURALLOOP_API_KEY` + `NEURALLOOP_BASE_URL` (custom), never argv or files. Other commands: `--setup` (start Ollama, download
  the local model and Rumik; prints `  setup: …` lines, then `Setup: ready`), `--signin` (Google sign-in in a real browser; the
  session is NotebookLM's), `--account` (both print `Account: {"signedIn", "email"}`), `--signout`, `--usage` (`NotebookLM usage: {known, available, fiveHour:{remaining, resetsAt}, weekly:{…}, podcast, video}`),
  `--check-ai` (tries every model in ai.json: prints
  `AI check: {role: {ok, provider, name, model, seconds} | {ok: false, provider, message}}` for `make`, `task:<item>`, `recall`; exit 3 if any fail), `--grade-recall` (stdin `{question, keyPoints, answer}`,
  stdout `{covered:[bool], score, feedback, missing, by}`; one parallel check per key point, word matching as fallback).
  `--ai-config PATH` (or `NEURALLOOP_AI_CONFIG`): the person's `ai.json` = `{engine, make:{provider, model, baseUrl},
  tasks:{<item>:{provider, model, baseUrl}}, recall:{provider, model, baseUrl}, voices:[A, B], voiceQuality:"fast"|"best"}` (Rumik 4-bit, about twice as fast, or 8-bit);
  flags override it. Progress lines on stdout:
  `  added chapter N: …` (NotebookLM), `  ✓ chapter N task (Xs)`, `  ↪ chapter N task: NotebookLM couldn't (…); making it with X`,
  `  … chapter N task: {Engine} limit reached…`, `  ✗ chapter N task: …`, final `Study site: PATH`. Exit 3 = setup needed.
- **Book folder** (`<app data>/books/<id>/`): `state.json` (pipeline state), `meta.json` (`path`, `addedAt`, `options`),
  `progress.json` (study progress from the site), `book-data.js`, `index.html`, `styles.css`, `app.js`, `pip-poses.js`,
  `.running` (the process id of the run preparing the book; a second run stops, a stale lock is ignored; interrupted
  `working` items go back to `todo` on the next run), `source.{pdf,epub}` (the app's own copy of the book), `book.json` (the app's data),
  `chapters/NN.{pdf,md}` (EPUB Markdown keeps figures as `![alt](img/NN-KK.ext)` with files in `chapters/img/`, captions as
  `*…*`, emphasis, lists), `media/`, `raw/`, `knowledge-graph.json`. `state.json` tasks record `by` (which engine made them).
- **`book-data.js`**: `window.BOOK = {title, source, made, dryRun, options, chapters:[{n, title, pages, read:{kind:"pdf",file}|{kind:"text",text},
  status:{study,graph,quiz,cards,mindmap,audio,video}, notes:{…}, graph, quiz, cards, mindmap, audio, video, guide, recall,
  explainer:{slides:[{title,points,narration,pose,audio,duration}]}, transcript}], graph, engine, provider, model}`.
  `transcript` points at `media/NN-podcast.json`: `{title, complete, lines:[{speaker,voice,text,start,clip}]}`, rewritten
  after every voiced line (`complete: false`, each line's `clip` in `media/NN-podcast-lines/`), so playback can start early. A NotebookLM podcast has no `transcript` and a NotebookLM video no
  `explainer`; making one clears what an earlier engine left.
- **Study progress** (`store`, saved as localStorage `nlbook:<title>` and `progress.json`): `{cards:{"n:i":{s,d,reps,last,due}},
  quiz, loop:{n:{prime,read,recall,map,space,closedShown}}, recall, remake, mapPos:{id:[x,y]}, mapSeen:[n], last:{n,stage},
  log:{"YYYY-MM-DD": seconds}}` (`log`: study time per local day, counted in 15 s ticks while the page is visible and in use).
- **Tauri commands**: `get_settings`, `set_settings`, `check_setup`, `start_pipeline(opts)`, `cancel_pipeline(bookId)`,
  `list_books`, `delete_book(bookId)`, `save_progress(bookId, data)`, `nudge_engaged`, `pause_nudges_today`.
  **Events**: `pipeline {bookId, line} | {bookId, done, code, stderr}`, `menu-add-book`, `toast`, `nudge {title, body}`.

## Work queue (do in this order)

0. **Baseline.** `make setup && make check` must pass on this machine before any change. If something fails because of the
   environment (for example a missing Chromium), fix the setup, not the tests. Commit: `Add NeuralLoop Books desktop app`.
1. ~~`docs/specs/05-own-pipeline-any-model.md`~~ — done: `auto` engine (NotebookLM, local fallback), any model, Rumik voices,
   recall checking, per-person `ai.json`, self-contained runtime.
2. `docs/specs/06-speed.md` — reading-order queue, media lane, and streamed podcast lines done; next: submit-then-poll for
   NotebookLM, a warm worker process.
3. `docs/specs/04-native-macos-app.md` + `docs/specs/07-every-device.md` — laptops first: the SwiftUI Mac app (unsigned download,
   "Open Anyway" once), then Windows and Linux laptops; iPad is a personal extra for now. Sign in with Google, the library lives
   in the person's Drive app folder, the Mac prepares books. Specs 01 and 02 then target the Swift files.
4. `docs/specs/02-book-import-and-parsing.md` — upload by picker or drag-and-drop, parse preview, correct parsing, tests on real-world shapes.
5. `docs/specs/01-pip-desktop-companion.md` — Pip on the desktop in a user-chosen corner.
6. Add a CI step that runs `python design/pip/generate_pip.py` and fails on `git diff --exit-code` (stale Pip files).

`docs/specs/03-pip-design-system.md` is the reference for anything showing Pip.

## Conventions

- **Python**: type hints on public functions, dataclasses for option bundles, no bare `except` (catch specific errors or
  `Exception` with a comment saying why), `ruff format` (line length 110). Tests: pytest, fixtures in `conftest.py`, builders in `testing.py`.
- **JavaScript**: ES modules, `const`/`let`, no globals except `window.BOOK`/`window.PIP`/`window.__TAURI__`, every user string
  through `esc()` before it touches `innerHTML`, `prettier` (width 120 site / 140 desktop). Tests: `node:test`.
- **Rust**: one module per responsibility, commands return `Result<T, String>` with `code: message` errors
  (`setup:`, `network:` …) that `friendlyError` strips, `cargo fmt` + `clippy -D warnings`, tests in `#[cfg(test)] mod tests`.
- **Accessibility**: every interactive element keyboard-reachable with a visible focus ring; `prefers-reduced-motion` disables
  Pip animation, confetti, and card flips; contrast AA in light and dark.
