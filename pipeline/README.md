# NeuralLoop book pipeline

A whole book in, learning loops out, in one command. The NeuralLoop Mac app runs this for you; you can also run it directly.

```bash
pip install -e ".[all]"             # or pick extras: anthropic, openai, rumik, notebooklm, video
python nl_book.py --dry-run --out /tmp/demo          # offline, with a practice model and voices
python nl_book.py mybook.epub --out neuralloop-mybook # NotebookLM when signed in (--signin), your own AI otherwise
```

For development: `pip install -e ".[dev]"`, then `pytest`.

Each run writes the book's folder: `book.json` (everything the app shows), `knowledge-graph.json` (the book map in
Understand-Anything's format), the chapters, and the media. Run the same command again to continue where it stopped;
`--retry` tries failed and limit-waiting items again. See `CLAUDE.md` in the repo root for every flag and file.

The book is sent to the AI you choose (Google NotebookLM through notebooklm-py, which uses unofficial APIs that can change, or
your own model). Use books you own.
