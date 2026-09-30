# NeuralLoop 🐾

**Turn any book you own into small learning loops, with Pip, a red panda who studies with you.**

Drop a PDF or EPUB on NeuralLoop and every chapter becomes a five-step loop that actually makes it stick:

1. **Listen & watch** — a two-host podcast and a short animated explainer video
2. **Read** — the chapter, with a reading plan that says what to read closely and what to skim
3. **Recall** — explain it in your own words (checked point by point), then a quiz
4. **Map** — remake the mind map from memory, then explore the concept graph
5. **Remember** — flashcards on a spaced-repetition schedule (FSRS)

Chapters unlock one at a time, and your **book map** grows as you map each chapter. Pip lives in your menu bar with a
gentle nudge now and then (never guilt), and "Your year with Pip" shows every minute you've studied.

## Highlights

- **Made for developers and deep reading**: technical books, figures, captions, and code-friendly reading.
- **Your AI, your choice**: Google NotebookLM by default; or Claude, OpenAI, OpenRouter, a free local model through
  Ollama or LM Studio, opencode, or Hermes. If one can't make something, another takes over, and the book always finishes.
- **Private by design**: your books stay on your Mac. Only the chapter being prepared goes to the AI you chose, and your
  library syncs to a hidden folder in *your own* Google Drive that only NeuralLoop can see.
- **Mac and iPad**: the Mac prepares books; the iPad picks up your library, progress, and cards.
- **Installs once**: everything it needs is inside the app.

## Get it

- **Mac (Apple silicon, macOS 14+)**: download the latest `NeuralLoop.dmg` from
  [Releases](../../releases), drag NeuralLoop into Applications, and open it. The first time, macOS double-checks with
  you: **System Settings → Privacy & Security → Open Anyway**.
- **iPad (iPadOS 17+)**: for now, build it from this repo with Xcode (see
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#installing-on-your-ipad)).

## Build from source

```bash
make setup    # once
make check    # tests and linters
make mac      # build and open the Mac app
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is a guided tour of the code, and [CLAUDE.md](CLAUDE.md) has the rules and
contracts. Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licensing

NeuralLoop is **source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE):

- ✅ free for personal use, learning, research, teaching, and other non-commercial purposes;
- ❌ not for commercial use, resale, or offering it as a paid product or service without a commercial license.

The NeuralLoop name and Pip are brand assets and aren't covered by the software license ([TRADEMARKS.md](TRADEMARKS.md)).
Third-party parts keep their own licenses ([NOTICE.md](NOTICE.md)); notably, the Rumik voices are non-commercial.

**Commercial licensing** and partnerships: open an issue titled "Commercial license" or reach out through
[github.com/NebulaTris](https://github.com/NebulaTris).

Security reports: please use GitHub's private vulnerability reporting ([SECURITY.md](SECURITY.md)).
