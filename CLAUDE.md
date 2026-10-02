# CLAUDE.md — working in the NeuralLoop repo

Read this first, every session. `docs/ARCHITECTURE.md` is the guided tour of every directory and module. Specs for new work live in `docs/specs`. The long-term vision is `docs/vision/BUILD_SPEC.md`
(where it disagrees with this file or the specs, **this file and `docs/specs` win**; notably the repo is source-available under the **PolyForm Noncommercial License 1.0.0**: `LICENSE`, with
`NOTICE.md` for third-party licenses (Rumik voices are CC BY-NC), `TRADEMARKS.md` for the name and Pip, `SECURITY.md`, and
`CONTRIBUTING.md` (contributions are licensed so the project can also be offered commercially)).

## What this repo is

NeuralLoop is an out-of-the-box learning tool for developers. It turns a book the user owns (PDF or EPUB) into five-step
learning loops per chapter, made with Google NotebookLM (the default) or any AI model the user plugs in (Anthropic, OpenAI,
OpenRouter, local Ollama, LM Studio or any OpenAI-compatible server, opencode, Hermes):
**Listen & watch → Read → Recall → Map → Remember**. Chapters unlock one at a time; the book map grows as chapters are mapped.
Pip, a cute red panda, lives in the menu bar and nudges gently (never guilt).

Two parts, one repo:

| Part | Language | Path | Runs as |
|---|---|---|---|
| Book pipeline | Python 3.10+ | `pipeline` | `python pipeline/nl_book.py BOOK …` (the app runs it from its bundled runtime) |
| Mac app | Swift 6 core + SwiftUI | `apple` | `NeuralLoop.app` (`make mac` to build and open, `make package` for the DMG) |

## Golden rules

1. **Test first.** Write the failing test, watch it fail, make it pass, refactor. Every task in `docs/specs` lists its tests.
2. **Logic stays pure and tested; screens stay thin.** Pure logic belongs in `pipeline/neuralloop_books/*.py` and
   `apple/Sources/NeuralLoopCore/*.swift` (tested with Swift Testing in `apple/Tests`). SwiftUI views (`apple/App/Views`) and
   services (`apple/App/Services`) only render, wire events, and do I/O.
3. **Never hand-edit generated files:** `apple/App/Resources/pip-rig.json`, `apple/App/Resources/PipLayers/*.png` (each layer at 3x, redrawn only when its art hash changes), and `pipeline/neuralloop_books/assets/pip-poses.js`
   (run `make pip`, i.e. `python design/pip/generate_pip.py`; animations are data in `ANIM` there, feeding both); `apple/App/Resources/AppIcon.icns` (`python design/pip/make_app_icon.py`);
   `design/dmg/background.tiff` (`python design/dmg/make_background.py`); `docs/readme/*` (the README's hero, poses, and
   demo GIF: `python design/readme/make_readme_art.py`, needs ffmpeg); `apple/NeuralLoop.xcodeproj` (XcodeGen writes it from `apple/project.yml`).
4. **`make check` must pass before every commit.** It runs the linters and all tests (Python and Swift).
5. **Small commits** with imperative messages (`Add book import preview`, `Fix EPUB nav with nested lists`).
6. **Respect contracts** (section "Contracts" below). If you change one, update this file and the tests in the same commit.
7. **No secrets, no user books, no generated media in git.** `.gitignore` covers build output, `.env`, media, and book folders.
8. **Copy for people is warm and plain.** Sentence case, no guilt ("You missed…" is never OK), errors say what happened and how
   to fix it. Pip is never angry or disappointed. The one exception is Silly mode (on by default, Settings → Nudges): after
   time away a nudge is a joke, step by step (default: tiny sad violin at 8 h, sad meow song at 12 h, a shocked "fahhh" at 24 h;
   the steps' sounds, hours, and count are the person's, plus an optional repeat of the last; each once per absence, never in quiet hours) with the `sad` or
   `shocked` pose; it always says what's ready, never scolds, and the fahhh has its own switch. No other screen uses those poses.

## Setup and commands

```bash
make setup      # once: creates .venv, installs hash-locked dev tools (scripts/dev-requirements.txt) + Chromium
make test       # all tests (pytest, swift test)
make lint       # ruff check + format over pipeline/ scripts/ design/ (root ruff.toml), shellcheck if installed
make check      # lint + test + check-generated (Pip rig/layers, icons, DMG background are current) (CI runs this plus an Xcode build and a Pip staleness check: .github/workflows/check.yml)
make mac        # build and open the Mac app (needs Xcode and XcodeGen: brew install xcodegen)
make package    # dist/NeuralLoop-<version>.dmg with the runtime inside (unsigned: "Open Anyway" once)
make runtime    # just the self-contained runtime (build/runtime)
make pip        # regenerate Pip's artwork
python pipeline/nl_book.py --dry-run --out /tmp/demo   # whole pipeline offline with a practice model and voices
```

Per part: `cd pipeline && pytest -q` · `cd apple && swift test`.

For development the app runs the pipeline from the repo's `.venv`, which `make setup` creates (override with `PY=`).
Development launch flags for screenshots: `-NLOpenSettings YES -NLSettingsPage Voices`, `-NLPreviewPanel YES`,
`-NLOpenBook <id> [-NLStage map] [-NLMapMode concepts|mind|remake] [-NLQuiz YES] [-NLBookMap YES]`, `-NLPipSheet YES` (every pose, animated), `-NLNudgePictures <folder>` (each silly nudge's Pip picture as a PNG), `-NLTestNudge sadViolin|sadMeow|shocked|gentle` (sends that test nudge), `-NLTour YES [-NLTourPage n]` (the guided tour), `-NLProfile YES`, `-NLMoveIn YES` (the
"move me into Applications" sheet, shown for real only when a Release build runs outside Applications).

## File map

### `pipeline` — Python package `neuralloop_books`
| File | Responsibility |
|---|---|
| `nl_book.py` | Entry point; friendly exit on Python < 3.10; calls `cli.main()` |
| `neuralloop_books/cli.py` | Argument parsing, engine choice, exit codes (0 ok, 2 invalid or unreadable book, 3 setup needed: key, model, Ollama, sign-in; 130 interrupted), final summary |
| `neuralloop_books/pipeline.py` | `Options`, `prepare_state` (split or resume, apply selection), `run(opts, engine)` (the book's OS lock, a text lane and a media lane, quota handling, book.json after every item; a setup error cancels the other items cleanly) |
| `neuralloop_books/chapters.py` | `split_book` → `split_pdf` (bookmarks, parts, 20-page fallback) and `split_epub` (nav/NCX TOC, chapters split at `#anchors` when several share one file, safety limits); blank bookmarks ignored, "Part II" divider pages skipped, a part far longer than the typical chapter whose bookmarks are chapter-sized (a "Projects" part) opened into those chapters ("Chapter N" and normal-length chapters always stay whole); front matter, reading guides, and back matter (appendices, glossary…) skipped (`config.FRONT_MATTER`); `UnreadableBookError`; `chapter_size` |
| `neuralloop_books/engines/local.py` | `LocalEngine`: any text model writes each item (checked, retried once with the reason); podcasts and explainers voiced by a speech engine |
| `neuralloop_books/engines/notebooklm.py` | `NotebookLMEngine`: adds chapters as sources, then `ChapterMaker` makes each item; a stale session is refreshed and the item retried once |
| `neuralloop_books/engines/auto.py` | `AutoEngine`: NotebookLM first, local engine for the whole run or per failed item (an item fails on its own if the fallback can't be set up); results tagged with who made them (`tasks.*.by`) |
| `neuralloop_books/notebook.py` | `ChapterMaker.make(task, chapter)`: one item via notebooklm-py; `is_quota_error`, `is_auth_error`; `open_client` |
| `neuralloop_books/models/` | Text models: `make_model(provider, model)`, `SetupError`, `QuotaError`, `communicate` (kills a timed-out child); `anthropic`, `openai_compat` (OpenAI, OpenRouter, any compatible `custom` URL), `hermes`, `ollama` (native API, JSON schemas), `opencode`, `fake` |
| `neuralloop_books/speech/` | Speech: `make_speech(name, voices)`; `rumik` (Rumik OSS-1 via mlx-audio, 8-bit or 4-bit; CC-BY-NC) is the only voice; `fake` for tests |
| `neuralloop_books/video.py` | Explainer → MP4: deterministic HTML/JS scene (`renderAt(t)`), frames from headless Chromium, PyAV x264 + narration (`NEURALLOOP_VIDEO=0` turns it off) |
| `neuralloop_books/recall.py` | `grade(model, question, keyPoints, answer)`: one check per key point in parallel, evidence must be in the answer and about the idea; `word_match` fallback |
| `neuralloop_books/aiconfig.py` | `load(path)` → `AIConfig` (engine, make, per-item `tasks`, recall model, voices, voice quality, podcast length) from the person's `ai.json` |
| `neuralloop_books/setup.py` | First run: `ensure_ollama` (bundled or installed), `ensure_model` (default by memory: `qwen3:8b`/`qwen3:4b`), `ensure_rumik` |
| `neuralloop_books/account.py` | Google sign-in via `notebooklm login`, `status()`, `sign_out()`, `usage()` (NotebookLM's five-hour and weekly allowance) |
| `neuralloop_books/audio.py` | `split_for_speech`, `join_wavs` (with pauses, returns durations), `to_m4a` (afconvert) |
| `neuralloop_books/context.py` | `chunks`, `source_for`: long chapters are condensed into notes that fit the model's budget |
| `neuralloop_books/schemas.py` | JSON schemas per item; Ollama uses them to constrain small models |
| `neuralloop_books/convert.py` | Model and NotebookLM outputs → our formats: `loose_json`, `quiz`, `flashcards`, `study`, `concept_graph`, `mind_map`, `podcast_script`, `explainer` |
| `neuralloop_books/book_graph.py` | Chapter graphs → one Understand-Anything knowledge graph; `similar_to` links across chapters |
| `neuralloop_books/bookdata.py` | `write(out, state, options)`: `book.json` and `knowledge-graph.json`, atomically; chapter text cached |
| `neuralloop_books/state.py` | `BookState` (state.json): statuses, `apply_selection`, `pending` (reading order), `counts` |
| `neuralloop_books/fake_client.py` | Offline NotebookLM with identical method names (`FakeClient`, `FakeQuotaClient`, `FakeStaleSessionClient`, `ENUMS`) |
| `neuralloop_books/selection.py`, `prompts.py`, `config.py`, `testing.py` | `parse_selection`; prompts (sent verbatim); task names, enums, timeouts, copy, `audio_length`; test book builders |
| `neuralloop_books/assets/` | Fonts and Pip's artwork for explainer videos |
| `tests` | Unit tests (`conftest.py` keeps every test away from the real NotebookLM account) · `sample/sample-book.epub` |

### `apple` — the Mac app and the iPad app (one codebase; AppKit and pipeline code behind `#if os(macOS)`)
| File | Responsibility |
|---|---|
| `Sources/NeuralLoopCore/` | Pure, tested: `FSRS`, `Loop`, `Cards`, `Activity` (year log), `Progress` (lenient decoding, `ProgressFile` keeps unreadable files aside, merges other devices' files with study time summed), `Book` (book.json, `KnowledgeGraph`), `Remake` (remake-from-memory scoring, `QuizProgress`, `PlainMath`), `GraphLayout` (force layout, sprout spiral, shortest path), `Nudges` (+ `NudgeMood`, `SillyStep`: Silly mode's editable steps by hours away), `AutoResume` (+ `RunRecord`, `BookFiles` path containment), `Shelf`, `BookNews`, `RecallCheck`, `AccountSummary` (who's signed in, same account or not, what to press next), `AIConfig`, `NotebookLMUsage`, `PipelineRun` (line parser, CLI arguments) |
| `App/NeuralLoopApp.swift` | Scenes (main window, Settings, menu-bar panel); starts the library's background loop at launch |
| `App/Services/Library.swift` | The shelf (read off the main thread, cached by modification date), adding and preparing books, auto-resume with back-off, notifications, `Nudger` |
| `App/Services/PipelineRunner.swift` | Runs the bundled runtime (or the repo in development); output to `pipeline.log`, followed by `LogFollower`; `once()` with a timeout |
| `App/Services/BookSession.swift`, `MediaCenter.swift`, `AISettings.swift`, `Keychain.swift`, `Notifier.swift`, `NudgeSounds.swift`, `NudgeOverlay.swift` | One open book's progress and study clock; shared players (panel + chapter); ai.json and keys; Keychain; system notifications (and the permission: asked on the welcome screen, shown in Settings → Nudges); each nudge mood's sound (`NeuralLoop-<name>.caf` in the app's Resources, else `~/Library/Sounds`, else the chime) and Pip picture; the big on-screen Pip for silly nudges (zooms in on the screen you're using, plays the sound, shrinks away when it ends) |
| `App/Views/` | `GuidedTour` (first launch and Help → Take the Tour: seven pages with animated scenes, the last one signs in), `AccountCards` (Settings → Account: `GoogleAccountCard` with one sign-in for NotebookLM and the library, `DevicesCard`), `LibraryView` (shelf, resume card, year log; the empty shelf's animated how-to is `EmptyShelfGuide`), `BookView` (chapters, five steps, book map), `Steps` (Listen, Read, Recall + quiz, Map, Remember), `StudyViews` (quiz, mind map, remake, book map), `GraphExplorer`, `QuickPanel`, `SettingsView` (Account, Your AI, Voices, Nudges), `PipView`, `Theme` |
| `Sources/NeuralLoopCore/Sync*.swift`, `DriveStore.swift`, `GoogleOAuth.swift` | Drive sync (spec 07): `SyncPlan` (who uploads/downloads what), `SyncEngine` (scan, plan, carry out; MD5 cache in `sync-state.json`), `GoogleDrive` REST client and `MemoryDrive` for tests, Google sign-in with PKCE |
| `App/Services/DriveAccount.swift`, `DriveSync.swift` | Google sign-in for Drive (tokens in the Keychain) and the sync loop (every 2 min, after studying, when a chapter opens); `-NLFakeDrive URL` (Debug only) uses `scripts/fake_drive.py` |
| `App/iPad/` | The iPad's entry point (`NeuralLoopPadApp`: library, book screens), its profile button and Settings sheet (account and sync). Books added on the iPad go to `inbox/` for the Mac (`Library.addToInbox`) |
| `project.yml` | XcodeGen spec: `NeuralLoop` (macOS; Debug knows the repo path, Release runs only its bundled runtime) and `NeuralLoopPad` (iPadOS 17, same App sources minus the pipeline runner, AI settings, notifications, move-in, and the Mac's App struct); `PipLayers` is a folder resource in both |

### Other
`scripts/build-runtime.sh` (self-contained runtime: Python 3.12.14, hash-locked wheels from `scripts/runtime-requirements.txt`
(refresh command at the top of the script), Ollama checked by SHA-256 and Team ID, Chromium; built in a temp folder and swapped
in only after every check; writes `.stamp` and `.neuralloop-runtime`; `make runtime`) · `scripts/package-mac.sh` (`make package`:
rebuilds a stale runtime, signs nested code inside out, builds the DMG with dmgbuild and Pip's drag-to-Applications window from
`design/dmg`, then checks it like a download) · `scripts/dev-signing-identity.sh`
(one stable self-signed identity so macOS remembers the app's permissions across rebuilds; `make mac` uses it) ·
`scripts/install-nudge-sounds.sh` (Silly mode's sounds, tags stripped: into `~/Library/Sounds`, or `OUT=apple/App/Resources` for the shipped ones; see NOTICE.md) · `design/pip/generate_pip.py` (Pip artwork source) · `design/readme/make_readme_art.py` (README pictures) · `design/pip/app-icon.svg` · `docs/DEVELOPMENT.md` · `Makefile`.

## Contracts

- **Pipeline CLI** (used by `apple/App/Services`): `nl_book.py BOOK --out DIR [--no-open] --media SPEC --style S --audio A
  --video V --language L [--engine auto|local|notebooklm] [--provider auto|anthropic|openai|openrouter|custom|ollama|opencode|hermes|fake]
  [--model M] [--base-url URL] [--context CHARS] [--audio-length auto|short|default|long] [--speech auto|rumik|fake] [--voices A,B] [--title T] [--dry-run] [--retry]`.
  `--title` names the book when it's first split (the app passes the original file's name, since it hands over its copy `source.pdf`; later runs keep the saved title).
  `--no-open` does nothing (kept for older callers). `auto` (default) = NotebookLM when signed in, the local engine (Ollama unless
  a key is set) for the whole run when not, and per item when NotebookLM fails or hits its limit (a stale NotebookLM session is
  refreshed and the item retried with NotebookLM once first). Keys only from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `OPENROUTER_API_KEY`, `NEURALLOOP_API_KEY` + `NEURALLOOP_BASE_URL` (custom), never argv or files. Other commands: `--setup`
  (start Ollama, download the local model and Rumik; prints `  setup: …` lines, then `Setup: ready`), `--signin` (Google sign-in
  in a real browser; the session is NotebookLM's), `--account` (both print `Account: {"signedIn", "email"}`), `--signout`,
  `--usage` (`NotebookLM usage: {known, available, fiveHour:{remaining, resetsAt}, weekly:{…}, podcast, video}`), `--check-ai`
  (prints `AI check: {role: {ok, provider, name, model, seconds} | {ok: false, provider, message}}` for `make`, `task:<item>`,
  `recall`; exit 3 if any fail), `--grade-recall` (stdin `{question, keyPoints, answer}`, stdout `{covered:[bool], score,
  feedback, missing, by}`). `--ai-config PATH` (or `NEURALLOOP_AI_CONFIG`): the person's `ai.json` = `{engine, make:{provider,
  model, baseUrl}, tasks:{<item>:{provider, model, baseUrl}}, recall:{provider, model, baseUrl}, voices:[A, B],
  voiceQuality:"fast"|"best", audioLength:"auto"|"short"|"default"|"long", hermesTools:false}` (Rumik 4-bit, about twice as fast, or 8-bit; podcast
  length for NotebookLM and the local engine, `auto` = short for chapters under ~30,000 characters); flags override it.
  Progress lines on stdout: `  added chapter N: …` (NotebookLM), `  ✓ chapter N task (Xs)`, `  ↪ chapter N task: NotebookLM
  couldn't (…); making it with X`, `  … chapter N task: {Engine} limit reached…` (the engine that actually ran the item),
  `  ✗ chapter N task: …`, final `Book: DIR`. Items waiting on a limit are retried on every run; `--retry` also retries failed
  items. Agent providers are locked down: opencode needs `--standalone` (else setup error) and runs with every tool permission
  denied; Hermes is refused unless ai.json `hermesTools: true`; both get an environment without API keys; chapter text is
  wrapped as data (`prompts.wrap_chapter`). Exit 2 = the book couldn't be read ("This book couldn't be read: …"), 3 = setup needed.
- **Book folder** (`~/Library/Application Support/app.neuralloop.books/books/<id>/`): `state.json` (pipeline state; tasks record
  `by`; `engine` stays `auto` when the fallback starts mid-run), `meta.json` (`path`, `originalPath`, `addedAt`,
  `options:{media, dryRun}`; "Prepare more" sets `media: "all"`), `progress.json` (study progress), `book.json` (the app's data),
  `knowledge-graph.json`, `.running` (an OS lock (`flock`) held by the run for its whole length and released even if it's killed;
  it holds the pid; a leftover file never blocks; interrupted `working` items go back to `todo` on the next run),
  `source.{pdf,epub}` (the app's own copy of the book), `chapters/NN.{pdf,md}` (EPUB Markdown keeps figures as
  `![alt](img/NN-KK.ext)` with files in `chapters/img/`, captions as `*…*`, emphasis, lists), `media/`, `raw/`, `pipeline.log`.
  Books made before the app may have `book-data.js` instead of `book.json`; the app still reads it. App-level:
  `ai.json`, `runs.json` (how each book's last run ended, for auto-resume back-off).
- **`book.json`**: `{title, source, made, dryRun, options, chapters:[{n, title, pages, read:{kind:"pdf",file}|{kind:"text",text},
  status:{study,graph,quiz,cards,mindmap,audio,video}, notes:{…}, graph, quiz, cards, mindmap, audio, video, guide, recall,
  explainer:{slides:[{title,points,narration,pose,audio,duration}]}, transcript}], graph, engine, provider, model}`.
  `transcript` points at `media/NN-podcast.json`: `{title, complete, lines:[{speaker,voice,text,start,clip}]}`, rewritten
  after every voiced line, so playback can start early. A NotebookLM podcast has no `transcript` and a NotebookLM video no
  `explainer`; making one clears what an earlier engine left. Paths in it are relative and must stay inside the book folder.
- **Study progress** (`progress.json`): `{cards:{"n:i":{s,d,reps,last,due}}, quiz:{n:{i, results:[bool]}},
  loop:{n:{prime,read,recall,map,space,closedShown}}, recall, remake:{n:{guess, best}}, mapPos:{id:[x,y]}, mapSeen:[n],
  last:{n,stage}, log:{"YYYY-MM-DD": seconds}, updatedAt, stamps:{"quiz.<n>"|"recall.<n>"|"remake.<n>"|"mapPos.<id>"|"last": ms}}` (`log`: study time per local day, counted in 15 s ticks while the
  book is in front and the app active). Decoding is lenient (a bad entry is skipped); a file that isn't JSON is kept aside as
  `progress.json.unreadable-<time>`. Merging: cards by latest `last`, loop steps by union, study time summed across devices (each file holds only its own), and
  quiz/recall/remake/mapPos/last per key by newest stamp. Study ticks don't bump `updatedAt`; keys are written sorted.
- **Drive app folder** (spec 07): files flat, named by path: `books/<id>/…` (only the Mac uploads these; never logs, locks,
  state, meta, source copies, or `devices/`), `books/<id>/progress/<device>.json` (each device uploads only its own; others are
  downloaded to `books/<id>/devices/<device>.json`), `inbox/<uuid>.{pdf,epub}` + `inbox/<uuid>.json` (`{title, addedAt}`; the Mac
  downloads, prepares under the title, then deletes; failed arrivals retry with back-off). A pad downloads media only for
  opened chapters and stages new books in `incoming/` before moving them into `inbox/`. Drive listing fields:
  `id,name,md5Checksum,size,modifiedTime`; duplicate names keep the newest and delete the rest. The device id lives in the
  Keychain (`SYNC_DEVICE_ID`, this device only); a clash (someone else writing our progress file) picks a new id.
  `sync-state.json` holds hashes, taken/sent inbox, removed books, per-progress uploaded md5s, inbox retries. `deviceinfo/<device>.json` (`{name, kind, lastSync}`: each device rewrites its own every 15 minutes while syncing; read for
  Settings → Account's device list, never placed on disk). `removed/<id>.json` marks a book removed on
  any device: it leaves the Drive, every device drops its copy, and its id is never reused (`Library.removeBook`, `removeAllBooks`).
- **Auto-resume**: the app starts a run on its own only when there's work (`AutoResume.hasWork`) and the last run allows it:
  after exit 2 or 3 it waits until settings change; other failures back off 5 minutes, doubling, up to 6 hours.

## Work queue (do in this order)

1. ~~`docs/specs/05-own-pipeline-any-model.md`~~ — done.
2. `docs/specs/06-speed.md` — reading-order queue, media lane, and streamed podcast lines done; next: submit-then-poll for
   NotebookLM, a warm worker process.
3. `docs/specs/04-native-macos-app.md` + `docs/specs/07-every-device.md` — the SwiftUI Mac app is the product (the Tauri app
   and the per-book study site are gone; their screens live in the app). Next: Pip's animation rig, first-launch setup screen,
   Windows and Linux laptops. Done: Pip's rig, the Google Drive library and the iPad app (spec 07; needs the owner's OAuth client
   ID in `apple/Config/Google.xcconfig`, see `docs/DEVELOPMENT.md`).
4. `docs/specs/02-book-import-and-parsing.md` — parse preview, correct parsing, tests on real-world shapes.
5. `docs/specs/01-pip-desktop-companion.md` — Pip on the desktop in a user-chosen corner.

`docs/specs/03-pip-design-system.md` is the reference for anything showing Pip.

## Conventions

- **Python**: type hints on public functions, dataclasses for option bundles, no bare `except` (catch specific errors or
  `Exception` with a comment saying why), `ruff format` (line length 110). Tests: pytest, fixtures in `conftest.py`, builders in `testing.py`.
- **Swift**: pure logic in `NeuralLoopCore` (Swift 6, `Sendable` value types, no UI imports), one file per responsibility,
  Swift Testing (`@Test`, `#expect`). Views stay thin; disk and process work stays off the main thread.
- **Accessibility**: every interactive element keyboard-reachable with a visible focus ring; Reduce Motion stops Pip's
  animation, card flips, and the book map's growth animation; contrast AA in light and dark.
