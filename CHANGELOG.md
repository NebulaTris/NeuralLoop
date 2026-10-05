# Changelog

## 0.2.1: chapters that make sense, and a dramatic Pip 🎻

- **Books split into the right chapters.** Guidebooks skip their "how to read this book" pages, contents, and
  appendices; blank bookmarks no longer rename or cut chapters; a long "Projects" part becomes one chapter per project;
  and textbooks keep each chapter whole instead of cutting it into sections. "Part II" title pages aren't chapters.
- **Books are named after their file** ("Agents guide"), not "source".
- **Silly mode** (on by default, Settings → Nudges): if you've been away a while, Pip gets dramatic, just for laughs.
  By default a tiny sad violin after 8 hours, a sad little song after 12, and a shocked "fahhh" after a whole day, each
  with a sad or shocked Pip. Each plays once, never in quiet hours, and opening NeuralLoop resets it. The steps are
  yours: pick each one's sound and hours, remove any, add more (sounds can repeat), and optionally repeat the last one
  every few hours.
- **A big Pip on screen** for silly nudges: Pip zooms in large in the middle of the screen you're using, with a big
  emoji, while the sound plays, then shrinks away when it ends. Click it to open NeuralLoop. Settings → Nudges lets
  you pick the big Pip or just a notification, set its volume, and send a test of each sound.
- **An empty shelf that shows what to do**: a little animated picture (your book flies along a dotted "whee!" arc into
  Pip's drop zone, and Pip hops when it lands) with three numbered steps.
- **A guided tour** when you first open NeuralLoop: seven short pages with little animations (bring a book, how Pip
  prepares it, the five steps, chapters unlocking, Pip in the menu bar), ending with sign-in and notifications. Help →
  Take the Tour shows it again.
- **One Google sign-in** in Settings → Account for NotebookLM and your library, with your name and email, which account
  each uses, and a list of your devices with when each last synced.
- Settings → Nudges shows whether notifications are on, with a button to System Settings if they're off.
- **A real progress loader** while podcasts, videos, and everything else are made: what's happening right now
  ("NotebookLM is recording the podcast", "Voicing the podcast"), who's making it, a percentage and progress bar, the
  time left, and each waiting item's place in line. Your own AI's podcasts and videos show their exact progress across
  every stage; NotebookLM shares none, so its percentage is an estimate from how long it usually takes.
- **Sign in with Google first:** the first time you open NeuralLoop, Google's sign-in opens right away, then the tour.
- **Notifications that make sense:** "Chapter ready" comes once, only for the chapter you can study next, and only when
  its whole loop is ready, podcast and video included. One switch turns every notification off, with separate switches
  for chapter ready, gentle nudges, and Silly mode.
- **Fixes from a full review:** books made of short parts, parts with a preface or index, numbered chapters, real
  chapters named like "Index structures", and substantial appendices all split correctly; every book keeps its name on
  later runs. Silly nudges only come when something is ready, never count against the usual nudges, and the big Pip
  stays away during calls, full-screen apps, and a locked screen. The device list shows each device once and tidies
  old ones, sign-out is always there, and the tour opens reliably.

## 0.2.0: the first public preview 🐾

NeuralLoop turns a book you own (PDF or EPUB) into five-step learning loops, one chapter at a time:
**Listen & watch → Read → Recall → Map → Remember**, with Pip, a red panda who studies with you.

**Get it**

1. Download `NeuralLoop-0.2.0.dmg` below (Apple silicon, macOS 14 or later).
2. Open it and drag Pip into your Applications folder.
3. Open NeuralLoop. The app isn't notarized yet, so the first time macOS asks you to confirm:
   **System Settings → Privacy & Security → Open Anyway**. You only do this once.

Everything is inside the download (Python, the book pipeline, local voices, a local model runner), so there's nothing
else to install.

**What's in it**

- Podcasts, explainer videos, reading plans, recall checks, quizzes, mind maps, concept graphs, and spaced-repetition
  flashcards for every chapter.
- Google NotebookLM by default, or your own AI: Claude, OpenAI, OpenRouter, Ollama, LM Studio, any OpenAI-compatible
  server, opencode, or Hermes. If one can't make something, another steps in.
- Podcasts and explainers voiced on your Mac with Rumik.
- A book map that grows as you go, and "Your year with Pip" for your study days.
- Pip in the menu bar, with at most one gentle nudge a day.

**Good to know**

- Google Drive sync and the iPad app are in the code but not switched on in this download yet. Until then, the iPad app
  can be built from source ([docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#installing-on-your-ipad)).
- The Rumik voices are licensed for non-commercial use only (CC BY-NC 4.0), like the app itself
  ([LICENSE](LICENSE), [NOTICE.md](NOTICE.md)).
- Found a bug? Please [open an issue](../../issues). Security problems: [SECURITY.md](SECURITY.md).
