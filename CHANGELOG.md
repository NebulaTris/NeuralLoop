# Changelog

## 0.2.1: chapters that make sense, and a dramatic Pip 🎻

- **Books split into the right chapters.** Guidebooks skip their "how to read this book" pages, contents, and
  appendices; blank bookmarks no longer rename or cut chapters; a long "Projects" part becomes one chapter per project;
  and textbooks keep each chapter whole instead of cutting it into sections. "Part II" title pages aren't chapters.
- **Books are named after their file** ("Agents guide"), not "source".
- **Silly mode** (on by default, Settings → Nudges): if you've been away a while, Pip gets dramatic, just for laughs.
  A tiny sad violin after 8 hours, a sad little song after 12, and a shocked "fahhh" after a whole day, each with a sad
  or shocked Pip in the notification. Each plays once, never in quiet hours, and opening NeuralLoop resets it. The
  "fahhh" has its own switch.
- **A big Pip on screen** for silly nudges: Pip zooms in large in the middle of the screen you're using, with a big
  emoji, while the sound plays, then shrinks away when it ends. Click it to open NeuralLoop. (Settings → Nudges.)
- **Notifications are asked for on the welcome screen**, and Settings → Nudges shows whether they're on, with a button
  to System Settings if they're off.

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
