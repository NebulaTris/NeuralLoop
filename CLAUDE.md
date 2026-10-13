# CLAUDE.md — working in the NeuralLoop repo

Read this first, every session. `docs/ARCHITECTURE.md` is the guided tour of every directory and module. `docs/NOTIFICATIONS.md`
explains every notification (rules, code, storage, how to test or move it). Specs for new work live in `docs/specs`. The long-term vision is `docs/vision/BUILD_SPEC.md`
(where it disagrees with this file or the specs, **this file and `docs/specs` win**; notably the repo is source-available under the **PolyForm Noncommercial License 1.0.0**: `LICENSE`, with
`NOTICE.md` for third-party licenses (Rumik voices are CC BY-NC; PyAV's FFmpeg links GPL x264/x265; the nudge sounds are the author's own), with texts in `licenses/` shipped in the app's Resources and `runtime/licenses`, `TRADEMARKS.md` for the name and Pip, `SECURITY.md`, and
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
   `shocked` pose; it always says what's ready, never scolds, and any step (the fahhh too) can be removed in the steps editor. No other screen uses those poses.
   A silly step only comes when something is ready (cards due or a half-done chapter); otherwise at most one warm "Pip's ready when you are" a week.
   Steps due at the same hour play one after another; silly steps never count toward the usual nudge's one-a-day limit or back-off; nothing silly
   comes while NeuralLoop is in front; leaving the app and studying count as a visit. The big on-screen Pip only shows when the screen isn't locked,
   nothing in front fills any display, and no app is recording (otherwise the notification carries the sound, which keeps to Focus; Focus itself
   can't be read without an entitlement).

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
`-NLOpenBook <id> [-NLStage map] [-NLMapMode concepts|mind|remake] [-NLQuiz YES] [-NLBookMap YES]`, `-NLPipSheet YES` (every pose, animated), `-NLNudgePictures <folder>` (each silly nudge's Pip picture as a PNG), `-NLTestNudge sadViolin|sadMeow|shocked|gentle` (sends that test nudge), `-NLTour YES [-NLTourPage n]` (the guided tour), `-NLNotify YES` (a Debug build may send scheduled notifications; without it, it never does), `-NLProfile YES`, `-NLMoveIn YES` (the
"move me into Applications" sheet, shown for real only when a Release build runs outside Applications).

## File map

### `pipeline` — Python package `neuralloop_books`
| File | Responsibility |
|---|---|
| `nl_book.py` | Entry point; friendly exit on Python < 3.10; calls `cli.main()` |
| `neuralloop_books/cli.py` | Argument parsing, engine choice, exit codes (0 ok, 2 invalid or unreadable book, 3 setup needed: key, model, Ollama, sign-in; 130 interrupted), final summary |
| `neuralloop_books/pipeline.py` | `Options`, `prepare_state` (split or resume, apply selection; an unreadable state.json is kept aside as `state.json.unreadable-<time>` and the book split again), `run(opts, engine)` (the book's OS lock, a text lane and a media lane, quota handling, book.json after every item; a setup error cancels the other items cleanly, puts working items back to todo (the one needing setup keeps the reason) and writes book.json; a kind NotebookLM didn't answer waits for the rest of the run like a limit) |
| `neuralloop_books/chapters.py` | `split_book` → `split_pdf` (bookmarks, parts, 20-page fallback) and `split_epub` (nav/NCX TOC read as a tree with the PDF rules: parts and a single whole-book entry open into their chapters, chapters keep their sections; chapters split at `#anchors` when several share one file; a book of mostly short pieces is grouped into chapter-sized runs ("Essay 1 and more"); figures copied once per book within `config.MAX_BOOK_IMAGE_BYTES` (later ones become their alt text); a chapter whose anchor is partway into a size-split file starts at the anchor; safety limits); never returns nothing (no text → `UnreadableBookError`); blank bookmarks ignored; "Part II" pages skipped only when they're a title page in front of chapters (never the last part), and a split that would skip everything falls back to the bookmarks as they are, or page chunks; parts open into their bookmarks only when those are chapters ("Chapter N", "Ch. N", "6. …"), or when the part is at least 30 pages and its bookmarks average 4+ pages and aren't mostly "6.1"-style sections (a short part holding sections stays one chapter), and a single top-level bookmark opens into its children; a part far longer than the typical chapter whose bookmarks are chapter-sized (a "Projects" part) opens into those chapters, but "Chapter N", "Ch. N", "6. …"/"6: …"/"6) …" chapters, a bare "6 …" among numbered siblings, chapters with "6.1"-style sections, and normal-length chapters stay whole; front matter, reading guides, and back matter (glossary, bibliography…) skipped only when the whole title matches (`config.FRONT_MATTER`); appendices kept when substantial (at least max(8 pages, half a typical chapter); EPUB at least max(20,000 characters, half typical)), skipped when short (`config.APPENDIX`, `is_appendix`); `UnreadableBookError`; `chapter_size` |
| `neuralloop_books/engines/local.py` | `LocalEngine`: any text model writes each item (checked, retried once with the reason); podcasts and explainers voiced by a speech engine |
| `neuralloop_books/engines/notebooklm.py` | `NotebookLMEngine`: adds chapters as sources (patient retries, only while nothing was made; a chapter that can't be added yet gets `NoSourceYet` and only its items wait; a source NotebookLM made but hadn't read in time is kept as `sourceId` with `sourceReady: false` and waited for by the next run, never uploaded again, and one it couldn't read is deleted and its items fail; a deleted notebook is made again once per run and a missing source added again once per chapter; at most 6 session reloads per run), then `ChapterMaker` makes each item; a refused session (every other NotebookLM process rotates Google's cookie) is reopened from the saved session, once for all items, and the item retried; a slow answer or dropped connection is retried after 20 s, 60 s and 120 s (`config.NOTEBOOKLM_RETRY_DELAYS`), then the item waits for the next run (`NotebookLMBusy`) instead of failing; a podcast or video already asked for is waited for, never asked for again |
| `neuralloop_books/engines/auto.py` | `AutoEngine`: NotebookLM first, local engine for the whole run or per failed item (an item fails on its own if the fallback can't be set up or stops working mid-run); podcasts and videos wait for NotebookLM (limit, no answer, a session that keeps failing); a fallback on this Mac makes one text item at a time while NotebookLM keeps two lanes (`leave_lane` hands the run's lane back before the fallback is got ready (a model download) and before queueing); `GenerationFailed` media fail as NotebookLM's, never local; results tagged with who made them (`tasks.*.by`) |
| `neuralloop_books/notebook.py` | `ChapterMaker.make(task, chapter)`: one item via notebooklm-py (podcasts, videos, quizzes and decks asked for once and waited for again; two whole waits, then `NotebookLMBusy`; a lost create reply is found again via `artifacts.list_*` (only an item listed as made from the chapter's source), never asked twice; a failed generation status becomes `QuotaError` (limit) or `GenerationFailed`; an item made but whose download failed keeps its `taskId` and waits (`DownloadLater`: never made again, here or locally) for the next run to download it, at most `config.NOTEBOOKLM_DOWNLOAD_TRIES` runs, then `NotDownloaded`, a `GenerationFailed`); `is_quota_error`, `is_auth_error`, `is_transient_error` (feature-unavailable, not-found, validation and unreadable answers are lasting; 502/503/504 only as HTTP statuses); `open_client` |
| `neuralloop_books/models/` | Text models: `make_model(provider, model)`, `SetupError`, `QuotaError`, `communicate` (kills a timed-out child); `anthropic`, `openai_compat` (OpenAI, OpenRouter, any compatible `custom` URL), `hermes`, `ollama` (native API, JSON schemas), `opencode`, `fake` |
| `neuralloop_books/speech/` | Speech: `make_speech(name, voices)`; `rumik` (Rumik OSS-1 via mlx-audio, 8-bit or 4-bit; CC-BY-NC) is the only voice; `fake` for tests |
| `neuralloop_books/video.py` | Explainer → MP4: deterministic HTML/JS scene (`renderAt(t)`), frames from headless Chromium, PyAV H.264 (h264_videotoolbox first, libx264 only as a last resort) + narration (`NEURALLOOP_VIDEO=0` turns it off) |
| `neuralloop_books/recall.py` | `grade(model, question, keyPoints, answer)`: one check per key point in parallel, evidence must be in the answer and about the idea; `word_match` fallback |
| `neuralloop_books/aiconfig.py` | `load(path)` → `AIConfig` (engine, make, per-item `tasks`, recall model, voices, voice quality, podcast length) from the person's `ai.json` |
| `neuralloop_books/setup.py` | First run: `ensure_ollama` (bundled or installed; started with a filtered environment, no provider keys), `ensure_model` (default by memory: `qwen3:8b`/`qwen3:4b`; runs on a run's first local item too, `any_will_do` when no model is named (any installed chat model will do; embedding models like `nomic-embed-text` never count, and Ollama never picks one), step "Downloading your Mac's AI (first time only)"), `ensure_rumik` |
| `neuralloop_books/account.py` | Google sign-in via `notebooklm login` (Chrome when installed, else Chromium downloaded once into the person's `browsers/` folder, never inside the signed app; the login runs in its own process group, so stopping a sign-in (SIGTERM, "Not now") closes its browser too and exits 130), `status()`, `sign_out()`, `usage()` (NotebookLM's five-hour and weekly allowance) |
| `neuralloop_books/audio.py` | `split_for_speech`, `join_wavs` (with pauses, returns durations), `to_m4a` (afconvert) |
| `neuralloop_books/context.py` | `chunks`, `source_for`: long chapters are condensed into notes that fit the model's budget |
| `neuralloop_books/schemas.py` | JSON schemas per item; Ollama uses them to constrain small models |
| `neuralloop_books/convert.py` | Model and NotebookLM outputs → our formats: `loose_json` (parses the raw answer first), `strip_citations` (only citations after prose, never in code or number lists), `plain_words`/`slug` (Unicode-aware), `quiz`, `flashcards`, `study`, `concept_graph`, `mind_map`, `podcast_script`, `explainer` |
| `neuralloop_books/book_graph.py` | Chapter graphs → one Understand-Anything knowledge graph; `similar_to` links across chapters (names compared by their words in any script, `convert.plain_words`, with C++/C# kept apart; links only across chapters; a name with no words links to nothing) |
| `neuralloop_books/bookdata.py` | `write(out, state, options)`: `book.json` and `knowledge-graph.json`, atomically; chapter text cached |
| `neuralloop_books/state.py` | `BookState` (state.json; `load` checks each chapter's shape and raises `UnreadableState`): statuses, `apply_selection`, `pending` (reading order), `counts` |
| `neuralloop_books/activity.py` | `Activity` (activity.json, the live progress feed: `begin`/`end` per item, `queue`, `close`; estimates from recent `timings`; `end` times an item from its own start, which a fallback resets) and `report(step, done=, total=, by=, restart=)`, which an item's own code calls through a context variable |
| `neuralloop_books/fake_client.py` | Offline NotebookLM with identical method names (`FakeClient`, `FakeQuotaClient`, `FakeStaleSessionClient`, `ENUMS`) |
| `neuralloop_books/selection.py`, `prompts.py`, `config.py`, `testing.py` | `parse_selection`; prompts (sent verbatim); task names, enums, timeouts, copy, `audio_length`; test book builders |
| `neuralloop_books/assets/` | Fonts and Pip's artwork for explainer videos |
| `tests` | Unit tests (`conftest.py` keeps every test away from the real NotebookLM account); `test_providers_e2e.py` runs every provider end to end against local stand-in services (`model_mocks.py`) · the sample book the dry run and tests use is `pipeline/sample/sample-book.{epub,pdf}` |

### `apple` — the Mac app and the iPad app (one codebase; AppKit and pipeline code behind `#if os(macOS)`)
| File | Responsibility |
|---|---|
| `Sources/NeuralLoopCore/` | Pure, tested: `FSRS`, `Loop`, `Cards`, `Activity` (year log), `Progress` (lenient decoding, `ProgressFile` keeps unreadable files aside, merges other devices' files with study time summed; `devicesSignature` so the shelf re-merges when sync rewrites `devices/*.json`; `mergedSameDevice` for two copies of this device's file; `CountedElsewhere`: study time already counted under an id given up after a clash), `Book` (book.json, `KnowledgeGraph`), `Remake` (remake-from-memory scoring, `QuizProgress`, `PlainMath`), `GraphLayout` (force layout, sprout spiral, shortest path), `Nudges` (+ `NudgeSettings.isQuiet`, `NudgeMood`, `SillyStep`: Silly mode's editable steps by hours away), `NudgeDelivery` (+ `NudgeMoment`: whether the big Pip shows; `player`: who plays the sound, the app itself for a test from Settings; `fillsAnyScreen`, `needsMoment`), `AutoResume` (+ `RunRecord`, `BookFiles` path containment), `Shelf`, `ChapterReady` ("chapter ready": once ever per chapter, only for the chapter you can study next, only when nothing is still coming (failed counts as settled), held through quiet hours and pauses; `message` names the podcast or video only when made), `TourRequest` (the tour's request number; one window shows it), `PrepActivity` + `PrepProgress` (activity.json → a progress bar and plain words), `PrepWindow` (which chapters to prepare just ahead of the reader: `--chapters`/`--media` specs, `hasWork`, `startAgain`, `notYet`; spec 08), `PlayCoverage` (+ `WatchProgress`: real playback, seeks and >2× ignored), `ReadingCredit` (+ `ReadingProgress`: reading time with input, visibility and skim-speed guards), `AutoSteps` (+ `Loop.completeIfOpen`: steps that complete themselves; spec 09), `InstallPlace` (where the app runs from: Applications, Downloads, the disk image; whether Pip offers to move in), `MoveInPlan` (moving in: copy and check before an older copy goes to the Trash, undo a failed step, quit only once the new copy opened), `PipRig` (plays pip-rig.json: layers, pivots, keyframes, CSS easing), `RecallCheck`, `AccountSummary` (who's signed in, same account or not, what to press next), `FirstSignIn` (whether the first launch's sign-in starts: never twice, never after "Not now", which also stops a sign-in underway; signed in to NotebookLM but not the library: connects the library), `RunProblemText` (the book card's line for an automatic run that failed), `AIConfig`, `NotebookLMUsage`, `PipelineEnvironment` (the run's environment: inherited provider keys, `NEURALLOOP_BASE_URL` and `NEURALLOOP_AI_CONFIG` dropped, only the saved keys added), `PipelineRun` (line parser, CLI arguments, `bookTitle`/`savedTitle`, invisible bidi and zero-width marks stripped) |
| `App/NeuralLoopApp.swift` | Scenes (main window, Settings, menu-bar panel); starts the library's background loop at launch |
| `App/Services/Library.swift` | The shelf (read off the main thread, cached by modification date), adding and preparing books, auto-resume with back-off, notifications, `Nudger`, just-ahead runs (`studyMoved`, `prepareEverything`); only runs the person started end in an alert, an automatic run's failure shows on its book card; the 5-minute NotebookLM usage check waits while a book is being prepared (each check rotates the session cookie) |
| `App/Services/PipelineRunner.swift` | Runs the bundled runtime (or the repo in development; `NEURALLOOP_PIPELINE`/`NEURALLOOP_PYTHON` overrides are Debug-only; keys come from a cache AISettings fills at launch and on save); output to `pipeline.log`, followed by `LogFollower`; `once()` with a timeout |
| `App/Services/BookSession.swift`, `MediaCenter.swift`, `PlayRecorder.swift`, `AISettings.swift`, `Keychain.swift`, `Notifier.swift`, `NudgeSounds.swift`, `NudgeOverlay.swift` | One open book's progress and study clock (`earn`: a step ticked off by real activity); shared players (panel + chapter) that report what really played about once a second; `PlayRecorder` (played stretches to the open book, or to progress.json every 15 s when it's closed); ai.json and keys; Keychain; system notifications (and the permission: asked on the welcome screen, shown in Settings → Nudges); each nudge mood's sound (`NeuralLoop-<name>.caf` in the app's Resources, else `~/Library/Sounds`, else the chime) and Pip picture; the big on-screen Pip for silly nudges (zooms in on the screen you're using, plays the sound, shrinks away when it ends; only when `NudgeDelivery.showsBigPip` says the moment is right; clicking it opens the library) |
| `App/Views/` | `GuidedTour` (first launch: `FirstLaunch` opens Google's sign-in first, then the tour; Help → Take the tour: the seven pages with animated scenes), `AccountCards` (Settings → Account: `GoogleAccountCard` with one sign-in for NotebookLM and the library, `DevicesCard`), `LibraryView` (shelf, resume card, year log; the empty shelf's animated how-to is `EmptyShelfGuide`), `BookView` (chapters, five steps, book map), `Steps` (Listen, Read, Recall + quiz, Map, Remember), `StepTracking` (`ReadingTracker`, `StepProgressRow`: each step's live progress), `StudyViews` (quiz, mind map, remake, book map), `GraphExplorer`, `QuickPanel`, `SettingsView` (Account, Your AI, Voices, Nudges), `LibraryDataCard` ("Your library": the room it takes, removing every book), `ProfileButton` (the library's account button: who's signed in, Settings, switch or sign out), `MoveInView` (`AppMover`: Pip offers to move into Applications, then reopens from there; the sheet can't close mid-move; half-made `.moving-<UUID>-NeuralLoop.app` copies from an interrupted move are swept at launch and before copying, `MoveInPlan.isLeftover`), `PipView`, `Theme` |
| `Sources/NeuralLoopCore/Sync*.swift`, `DriveStore.swift`, `GoogleOAuth.swift` | Drive sync (spec 07): `SyncPlan` (who uploads/downloads what), `SyncEngine` (scan, plan, carry out; MD5 cache in `sync-state.json`), `GoogleDrive` REST client and `MemoryDrive` for tests, Google sign-in with PKCE |
| `App/Services/DriveAccount.swift`, `DriveSync.swift` | Google sign-in for Drive (tokens in the Keychain) and the sync loop (every 2 min, after studying, when a chapter opens); `-NLFakeDrive URL` (Debug only) uses `scripts/fake_drive.py` |
| `App/iPad/` | The iPad's entry point (`NeuralLoopPadApp`: library, book screens), its profile button and Settings sheet (account and sync; `DriveSyncCard`: Drive sign-in, what's synced, when). Books added on the iPad go to `inbox/` for the Mac (`Library.addToInbox`) |
| `project.yml` | XcodeGen spec: `NeuralLoop` (macOS; Debug knows the repo path, Release runs only its bundled runtime) and `NeuralLoopPad` (iPadOS 17, same App sources minus the pipeline runner, AI settings, notifications, move-in, and the Mac's App struct); `PipLayers` is a folder resource in both |

### Other
`scripts/build-runtime.sh` (self-contained runtime: Python 3.12.14, hash-locked wheels from `scripts/runtime-requirements.txt`
(refresh command at the top of the script), Ollama checked by SHA-256 and Team ID, Chromium; pip's launcher scripts and sounddevice's Windows DLLs removed, and a check that no file holds the build folder's or
the builder's home path; built in a temp folder and swapped
in only after every check; writes `.stamp` and `.neuralloop-runtime`; `make runtime`) · `scripts/package-mac.sh` (`make package`:
rebuilds a stale runtime, signs nested code inside out, builds the DMG with dmgbuild and Pip's drag-to-Applications window from
`design/dmg`, then checks it like a download) · `scripts/dev-signing-identity.sh`
(one stable self-signed identity so macOS remembers the app's permissions across rebuilds; `make mac` uses it) ·
`scripts/install-nudge-sounds.sh` (Silly mode's sounds, tags stripped: into `~/Library/Sounds`, or `OUT=apple/App/Resources` for the shipped ones; see NOTICE.md) · `design/pip/generate_pip.py` (Pip artwork source) · `design/readme/make_readme_art.py` (README pictures) · `design/pip/app-icon.svg` · `docs/DEVELOPMENT.md` · `Makefile`.

## Contracts

- **Pipeline CLI** (used by `apple/App/Services`): `nl_book.py BOOK --out DIR [--no-open] --media SPEC --style S --audio A
  --video V --language L [--engine auto|local|notebooklm] [--provider auto|anthropic|openai|openrouter|custom|ollama|opencode|hermes|fake]
  [--model M] [--base-url URL] [--context CHARS] [--audio-length auto|short|default|long] [--speech auto|rumik|fake] [--voices A,B] [--title T] [--instructions TEXT] [--dry-run] [--retry]` (the app always sends `--chapters` with the just-ahead window, or `all`).
  `--instructions` is the style note for podcasts and videos (NotebookLM and the local engine) and the local engine's study guide
  (default `config.DEFAULT_INSTRUCTIONS`, a friendly deep-dive for software engineers).
  `--title` names the book when it's first split (later runs keep the saved title). The app sends it as one argument, `--title=T`, on every run,
  from meta.json `title` (it hands over its copy `source.pdf`, so the file name would be wrong).
  `--no-open` does nothing (kept for older callers). `auto` (default) = NotebookLM when signed in, the local engine (Ollama unless
  a key is set) for the whole run when not, and per item when NotebookLM fails or hits its limit, except that a podcast or video at NotebookLM's limit, or that NotebookLM didn't answer after patient retries, waits for it (people want NotebookLM's own; `waiting`, retried when live usage says it can) (a refused NotebookLM session is
  reopened from the saved one and the item retried with NotebookLM once first). Keys only from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `OPENROUTER_API_KEY`, `NEURALLOOP_API_KEY` + `NEURALLOOP_BASE_URL` (custom), never argv or files. Other commands: `--setup`
  (start Ollama, download the local model and Rumik; prints `  setup: …` lines, then `Setup: ready`), `--signin` (Google sign-in
  in a real browser; the session is NotebookLM's), `--account` (both print `Account: {"signedIn", "email"}`), `--signout`,
  `--usage` (`NotebookLM usage: {known, available, fiveHour:{remaining, resetsAt}, weekly:{…}, podcast, video}`), `--check-ai`
  (prints `AI check: {role: {ok, provider, name, model, seconds} | {ok: false, provider, message}}` for `make`, `task:<item>`,
  `recall`; exit 3 if any fail; with `--provider`/`--model`/`--base-url` it checks that model as `make`), `--grade-recall` (stdin `{question, keyPoints, answer}`, stdout `{covered:[bool], score,
  feedback, missing, by}`). `--ai-config PATH` (or `NEURALLOOP_AI_CONFIG`): the person's `ai.json` = `{engine, make:{provider,
  model, baseUrl}, tasks:{<item>:{provider, model, baseUrl}}, recall:{provider, model, baseUrl}, voices:[A, B],
  voiceQuality:"fast"|"best", audioLength:"auto"|"short"|"default"|"long", hermesTools:false}` (Rumik 4-bit, about twice as fast, or 8-bit; podcast
  length for NotebookLM and the local engine, `auto` = short for chapters under ~30,000 characters); flags override it. A task or recall
  choice inherits a missing model or `baseUrl` only from a choice for the same provider. A `custom` address gets `http://` and `/v1`
  when they're missing; with no model, a custom server's first listed model (LM Studio's loaded one) is used, and Ollama's default.
  Progress lines on stdout: `  added chapter N: …` (NotebookLM), `  ✓ chapter N task (Xs)`, `  ↪ chapter N task: NotebookLM
  couldn't (…); making it with X`, `  … chapter N task: {Engine} limit reached…` (the engine that actually ran the item),
  `  ✗ chapter N task: …`, final `Book: DIR`. Items waiting on a limit are retried on every run; `--retry` also retries failed
  items. Agent providers are locked down: opencode needs `--standalone` (else setup error) and runs with every tool permission
  denied, with `HOME` and `XDG_CONFIG_HOME` in an empty folder so the person's global opencode config can't loosen that
  (its data, cache, and state folders are kept for sign-ins); Hermes is refused unless ai.json `hermesTools: true`; both get an environment without API keys; chapter text is
  wrapped as data (`prompts.wrap_chapter`). Exit 2 = the book couldn't be read ("This book couldn't be read: …"), an invalid chapter/media selection, or the book already being prepared (a corrupt state.json is not exit 2); 3 = setup needed (also `--engine notebooklm` without the library). `--context` below 1000 is raised to 1000. `--parallel` defaults to 1 only for `--engine local` with a model on this Mac.
- **Book folder** (`~/Library/Application Support/app.neuralloop.books/books/<id>/`): `state.json` (pipeline state; tasks record
  `by`; a chapter's `sourceId` is its NotebookLM source, with `sourceReady: false` while NotebookLM is still reading it; NotebookLM tasks may hold `taskId` and `requestedAt` (epoch seconds) until done or failed, and the next run waits for that id first (plus `downloadTries` when it was made but its download failed); `timings: {"<maker>:<item>": [seconds…]}` (last 10, for the loader's estimates); `engine` stays `auto` when the fallback starts mid-run), `meta.json` (`path`, `originalPath`, `addedAt`, `title`
  (the inbox sidecar's, else the original file's name, else "Your book"; never an inbox UUID; `PipelineCommand.bookTitle`), `options:{media, dryRun}`; "Prepare more" sets `media: "all"`, which means prepare everything; otherwise each run asks for the just-ahead window, `PrepWindow`), `progress.json` (study progress), `book.json` (the app's data),
  `knowledge-graph.json`, `activity.json` (what the run is making right now, for the app's progress loader: `{updated, ended, pid,
  items:[{n, item, by, step, started, updated, done, total, fraction, expected}], queue:[{n, item}]}`; `fraction` is one overall measure
  across an item's stages (local podcasts: script 5 %, lines 10–95 %, mix; local videos: explainer 5 %, slides 10–40 %, frames 40–98 %);
  NotebookLM gives no progress, so the app estimates it from `expected` and says "About N%"; written atomically, at most every
  half second unless the step changes, `ended: true` when the run ends; Mac only, never synced; `neuralloop_books/activity.py`),
  `.running` (an OS lock (`flock`) held by the run for its whole length and released even if it's killed;
  it holds the pid; a leftover file never blocks; interrupted `working` items go back to `todo` on the next run),
  `source.{pdf,epub}` (the app's own copy of the book), `chapters/NN.{pdf,md}` (EPUB Markdown keeps figures as
  `![alt](img/NN-KK.ext)` with files in `chapters/img/`, captions as `*…*`, emphasis, lists), `media/`, `raw/`, `pipeline.log`.
  Books made before the app may have `book-data.js` instead of `book.json`; the app still reads it. App-level:
  `ai.json`, `runs.json` (how each book's last run ended, for auto-resume back-off); UserDefaults `prepareEverything` (Settings → Your AI → "Prepare whole books right away", off by default), `chapterReadyWatching` and
  `chapterReadyAnnounced` (`{bookId: [chapter]}`, pruned to books on the shelf).
- **`book.json`**: `{title, source, made, dryRun, options, chapters:[{n, title, pages, read:{kind:"pdf",file}|{kind:"text",text},
  status:{study,graph,quiz,cards,mindmap,audio,video}, notes:{…}, graph, quiz, cards, mindmap, audio, video, guide, recall,
  explainer:{slides:[{title,points,narration,pose,audio,duration}]}, transcript}], graph, engine, provider, model}`.
  `transcript` points at `media/NN-podcast.json`: `{title, complete, lines:[{speaker,voice,text,start,clip}]}`, rewritten
  after every voiced line, so playback can start early. A NotebookLM podcast has no `transcript` and a NotebookLM video no
  `explainer`; making one clears what an earlier engine left. Paths in it are relative and must stay inside the book folder.
- **Study progress** (`progress.json`): `{cards:{"n:i":{s,d,reps,last,due}}, quiz:{n:{i, results:[bool]}},
  loop:{n:{prime,read,recall,map,space,closedShown}}, recall, remake:{n:{guess, best}}, mapPos:{id:[x,y]}, mapSeen:[n],
  last:{n,stage}, log:{"YYYY-MM-DD": seconds}, watch:{n:{audio:[[s,e]…], video:[[s,e]…]}}, reading:{n:{pages:{"<0-based page>": seconds}, count, last}}, updatedAt, stamps:{"quiz.<n>"|"recall.<n>"|"remake.<n>"|"mapPos.<id>"|"last": ms}}` (`log`: study time per local day, counted in 15 s ticks (plus the part of one when the app quits or, on the iPad, goes to the background) while the
  book is in front and the app active). Decoding is lenient (a bad entry is skipped); a file that isn't JSON is kept aside as
  `progress.json.unreadable-<time>` (state.json likewise as `state.json.unreadable-<time>`). Merging: cards by latest `last`, loop steps by union, study time summed across devices (each file holds only its own; time a device already counted under an id it gave up after a clash lives in `books/<id>/.counted-elsewhere.json` as `{byID:{<old id>:{day: seconds}}}` (the older `{log, ids}` is read with the time under the first id); each old id's part is left out of what goes up under the new id only when that id's progress file is in the Drive being synced to, and taken off when merging only while `devices/<old id>.json` is here), and
  quiz/recall/remake/mapPos/last per key by newest stamp, watch spans by union, reading page seconds and `count`/`last` by max.
  Study ticks, listening and reading don't bump `updatedAt` (tracking is written at most every 15 s; `watch`/`reading` are left out while empty); keys are written sorted.
- **Drive app folder** (spec 07): files flat, named by path: `books/<id>/…` (only the Mac uploads these; never logs, locks,
  state, meta, source copies, or `devices/`), `books/<id>/progress/<device>.json` (each device uploads only its own; others are
  downloaded to `books/<id>/devices/<device>.json`), `inbox/<uuid>.{pdf,epub}` + `inbox/<uuid>.json` (`{title, addedAt}`; the Mac
  downloads, prepares under the title, then deletes; failed arrivals retry with back-off). A pad downloads media only for
  opened chapters and stages new books in `incoming/` before moving them into `inbox/`. Drive listing fields:
  `id,name,md5Checksum,size,modifiedTime`; duplicate names keep the newest and delete the rest. The device id lives in the
  Keychain (`SYNC_DEVICE_ID`, this device only); a clash (someone else writing our progress file; only the newest copy of each own file is checked) picks a new id; the old id's files stay (they belong to the copy too). A local `devices/<dev>.json` is deleted once that file leaves a full listing; an inbox book is never uploaded in a sync where its sidecar failed.
  `sync-state.json` holds hashes (`uploaded`, plus `attempted`: the last 5 md5s sent without an answer, counted as ours; `retired`: md5s this device wrote under an id it gave up, removed from the Drive and never downloaded as another device; kept per Google account as a SHA-256 prefix of the address, together with `removed`, `removeFromDrive`, `sent`, `dropInbox`/`dropInboxBefore` and `sentLogs`; global `removedEver` (ids never reused) and `clashed`), `untitled` inbox books (a Mac waits one sync for a sidecar; a pad uploads the sidecar first), taken/sent inbox, removed books, per-progress uploaded md5s, inbox retries, and this device's note state
  (`noteAt`, `noteName`, `noteDevice`) plus cached copies of other devices' notes (`notes`, re-read when their md5 changes). `deviceinfo/<device>.json`
  (`{name, kind, lastSync}`): each device writes only its own, when it's missing, when the name or id changes, or every 15 minutes while syncing;
  duplicates are tidied by any device (newest kept); after a clash the new id writes its note and the old id's is deleted; notes the Drive hasn't seen rewritten for 90 days
  (by Drive's own `modifiedTime`, against the newest in the listing; never a device's clock, and the self-reported `lastSync` is only shown)
  are hidden and deleted by any device; Drive sign-out stops syncing first (a sync underway gets up to 15 s), then deletes this device's
  note (best effort), and the engine never writes the note again until the next sign-in (a note on its way up is taken back down). Names are shown cleaned (no control characters or invisible
  bidi/zero-width marks, joiners and emoji tags kept, at most 60) and `lastSync` is clamped to [0, now + 1 day]. Read for Settings → Account's device list, never placed on disk. `removed/<id>.json` marks a book removed on
  any device: it leaves the Drive, every device drops its copy, and its id is never reused (`Library.removeBook`, `removeAllBooks`).
- **Auto-resume**: the app starts a run on its own only when there's work inside the just-ahead window (`AutoResume.hasWork(book, window:)`;
  failed items ignored), when a study step moves the window (`BookSession.complete` → `Library.studyMoved(in:)`), or right after a
  successful run that ended with the window moved and work left (`PrepWindow.startAgain`), and the last run allows it:
  after exit 2 or 3 it waits until settings change; other failures back off 5 minutes, doubling, up to 6 hours.

## Work queue (do in this order)

1. ~~`docs/specs/05-own-pipeline-any-model.md`~~ — done.
2. `docs/specs/06-speed.md` — reading-order queue, media lane, streamed podcast lines and submit-then-poll for NotebookLM done;
   next: a warm worker process.
3. `docs/specs/04-native-macos-app.md` + `docs/specs/07-every-device.md` — the SwiftUI Mac app is the product (the Tauri app
   and the per-book study site are gone; their screens live in the app). Next: Windows and Linux laptops. Done: Pip's rig,
   the first-launch sign-in and guided tour, the Google Drive library and the iPad app (spec 07; needs the owner's OAuth client
   ID in `apple/Config/Google.xcconfig`, see `docs/DEVELOPMENT.md`).
4. `docs/specs/02-book-import-and-parsing.md` — parse preview, correct parsing, tests on real-world shapes.
5. `docs/specs/01-pip-desktop-companion.md` — Pip on the desktop in a user-chosen corner.
6. ~~`docs/specs/08-just-ahead.md`~~ and ~~`docs/specs/09-steps-complete-themselves.md`~~ — done.

`docs/specs/03-pip-design-system.md` is the reference for anything showing Pip.

## Conventions

- **Python**: type hints on public functions, dataclasses for option bundles, no bare `except` (catch specific errors or
  `Exception` with a comment saying why), `ruff format` (line length 110). Tests: pytest, fixtures in `conftest.py`, builders in `testing.py`.
- **Swift**: pure logic in `NeuralLoopCore` (Swift 6, `Sendable` value types, no UI imports), one file per responsibility,
  Swift Testing (`@Test`, `#expect`). Views stay thin; disk and process work stays off the main thread.
- **Accessibility**: every interactive element keyboard-reachable with a visible focus ring; Reduce Motion stops Pip's
  animation, card flips, and the book map's growth animation; contrast AA in light and dark.
