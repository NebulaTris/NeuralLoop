# NeuralLoop book pipeline (NotebookLM POC)

A whole book in, a cute study site out, in one command.

## Setup (once)
For development: `pip install -e ".[dev]"`, then `pytest` (and `cd site && npm install && npm test`).

## Setup for use
```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install "notebooklm-py[browser]" pypdf
python -m playwright install chromium
notebooklm login
```

## Run
```bash
python nl_book.py --dry-run                         # try the whole flow offline first
python nl_book.py ~/Books/my-book.pdf               # or .epub
python nl_book.py ~/Books/my-book.pdf --media 1-5 --style kawaii --audio debate
```
Open `neuralloop-<book>/index.html` any time; it updates itself while the pipeline runs.

Re-run the same command to continue after NotebookLM's daily limit, or add `--retry` to retry failed items.

| Option | Meaning |
|---|---|
| `--chapters 1-5` | only these chapters (default all) |
| `--media 1-3` | chapters that also get a podcast + video (default 1-3, "all", or "none") |
| `--audio` | deep-dive, brief, critique, debate, none |
| `--video` | explainer, brief, short, none |
| `--style` | kawaii (default), whiteboard, classic, watercolor, anime, paper-craft, retro-print, heritage, auto |
| `--language` | e.g. en, hi |
| `--parallel 2` | items made at the same time |

The book is sent to Google through notebooklm-py (unofficial APIs that can change). Use books you own; the site stays on your computer.
