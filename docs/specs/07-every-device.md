# Spec 07 — Your library on every device

Status: next (with spec 04) · Read first: `CLAUDE.md`, specs 04 and 05 · Touches: the Swift app (`apple/`), `pipeline/`

## What the person experiences

- **On a laptop:** drop a PDF or EPUB on NeuralLoop. That's the only step.
- **On the iPad:** open NeuralLoop, sign in with Google, and the library is already there: every book, where you left off,
  your cards, maps, and your year with Pip. You can also add a book from the iPad (Files, share sheet, or drag and drop).
- No iCloud setting, no file copying, no "sync" button. Progress made on one device shows up on the others.
- A book added on the iPad says "Your Mac will prepare this the next time it's awake" and appears, chapter by chapter,
  as the Mac prepares it.

## Decisions (from the owner)

| Topic | Decision |
|---|---|
| First platforms | macOS and iPadOS, for personal use. Windows and Linux later, with their own app on the same library and account |
| App | One SwiftUI codebase, multiplatform target (macOS 14+, iPadOS 17+). Mac-only parts: the pipeline, menu bar, desktop Pip |
| Sign-in | Google, on every device. It's the identity, the key to the library, and (on the Mac) NotebookLM's session |
| Where the library lives | A private app folder in the person's own Google Drive (`drive.appdata` scope): invisible in Drive's UI, free, and it works on Windows and Linux later (iCloud wouldn't) |
| Who prepares books | The person's Mac. Free and private. A cloud worker is out of scope |
| Default engine | NotebookLM first (`auto`), local open-source models whenever it can't; keys optional for customisation |
| Recall checking | An open-source model on the device: `gemma2:2b` through Ollama on the Mac today; in the Swift app, the same kind of small open model through MLX Swift on both Mac and iPad (no Python start-up, works offline). Word matching if no model is available |
| Voices | Rumik "fast" (4-bit) by default |

## How it works

```
 Mac ──────────────────────────────┐                ┌───────────────── iPad
 drop a book → pipeline (NotebookLM,│                │  sign in → library appears
 Ollama, Rumik, video) → book folder│   Google Drive │  study offline; recall on device
 upload chapter by chapter ────────►│  app folder    │◄──── download what's opened
 pick up inbox/ books  ◄────────────│  (private)     │───── add a book → inbox/
 merge progress  ◄─────────────────►│                │◄───► merge progress
```

### Drive app folder layout

```
library.json                       [{id, title, addedAt, chapters, status}] — the shelf
books/<id>/book.json               the book-data payload (same as book-data.js today)
books/<id>/chapters/NN.{pdf,md}, chapters/img/…, media/…, knowledge-graph.json
books/<id>/progress/<deviceId>.json   each device's own progress: never overwritten by another device
inbox/<uuid>.{pdf,epub} + inbox/<uuid>.json   books added on a device that can't prepare them ({title, options, addedBy})
devices.json                       [{id, name, kind: "mac"|"ipad", lastSeen}]
```

### Progress without conflicts

Each device writes only its own `progress/<deviceId>.json`. Reading merges all of them, so nothing is ever lost:

- cards: per card, the review with the latest `last` wins (FSRS state travels with it);
- loop steps: union (a step done anywhere is done);
- study log: per day, the sum across devices;
- quiz, recall, remake: latest by timestamp; `mapPos`: latest device wins; `last` (where you left off): latest.

This merge is a pure function in `NeuralLoopCore` with unit tests (and the same rules in Python for the CLI).

### Preparing books

- The Mac app watches `inbox/` (on launch, every few minutes while awake, and on a push from Drive's changes API).
  It downloads the book, runs the pipeline with the person's `ai.json`, and uploads each item as it's made, so the iPad
  shows chapter 1 long before the whole book is done.
- The iPad never runs the pipeline; its Add sheet uploads to `inbox/` and shows the book as "Waiting for your Mac".
- Only the chapter being prepared is ever sent to an AI; the library stays in the person's own Drive.

### Downloads on the iPad

`book.json`, chapter text, and graphs download with the shelf (small). Media (podcasts, videos, PDFs) download when a chapter
is opened, and the next chapter's media download in the background, so studying works offline once a chapter is open.

## One-time setup (owner, documented step by step in `docs/DEVELOPMENT.md`)

1. Google Cloud console → new project "NeuralLoop" → OAuth consent screen (External, **Testing**, add your own account as a
   test user) → Credentials → OAuth client ID of type **iOS** (bundle id `app.neuralloop.books`), used by both the Mac and
   iPad apps. Scopes: `openid`, `email`, `profile`, `https://www.googleapis.com/auth/drive.appdata`.
2. Put the client ID in `apple/Config/Google.xcconfig` (not committed; a `.example` file is).
3. Install Xcode (App Store) to build for the iPad. With a free Apple ID, apps installed on your own devices need
   re-signing every 7 days; a paid developer account removes that and enables TestFlight.

Sign-in uses `ASWebAuthenticationSession` with PKCE (the system browser sheet Google accepts), and tokens live in the
Keychain. On the Mac, the first sign-in continues into NotebookLM's browser sign-in (`neuralloop --signin`) in the same flow.

## Tests (write first)

- `NeuralLoopCore`: progress merge (every rule above, including two devices reviewing the same card), library diffing
  (what to upload or download), inbox job parsing, Drive path building.
- Drive client against a fake Drive (in-memory) with the same REST shapes: upload, list by parent, download, changes.
- Screen models: shelf shows "Waiting for your Mac" for inbox books; opening a chapter queues its media download.
- Pipeline: `--upload` hook is not needed; the Mac app uploads from the book folder, so the folder contract is the test.

## Definition of done

- Drop a book on the Mac; sign in on the iPad; chapter 1 is studyable on the iPad while the Mac is still preparing chapter 3.
- Review cards on the iPad offline; reconnect; the Mac shows the same card schedule and the study log counts both.
- Add a book on the iPad; when the Mac wakes, it prepares it and the iPad shows it without any action.
