# Third-party notices

NeuralLoop's own code is licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`). It builds on, and the
packaged Mac app bundles, the components below, each under its own license. Where a component restricts use, that
restriction applies to anyone using the component through NeuralLoop.

## Components with restrictions to know about

| Component | Used for | License | What it means |
|---|---|---|---|
| **Rumik OSS-1** voices (`rumik-ai/rumik-oss-1-mlx-4bit`, `-8bit`), downloaded on first use | Podcast and explainer narration made on your Mac | **CC BY-NC 4.0** | **Non-commercial use only.** Anyone selling NeuralLoop, or using it commercially, needs a separate licence from Rumik or a different voice engine. |
| **Google NotebookLM**, through `notebooklm-py` | The default way study material is made | Google's terms of service; `notebooklm-py` is MIT | `notebooklm-py` uses unofficial interfaces that can change at any time. Check Google's terms before any commercial use. |

## Fonts (bundled)

| Font | License | Text |
|---|---|---|
| Fredoka | SIL Open Font License 1.1 | `licenses/Fredoka-OFL.txt` |
| Atkinson Hyperlegible | SIL Open Font License 1.1 | `licenses/AtkinsonHyperlegible-OFL.txt` |

## Bundled in the Mac app's runtime

The runtime (built by `scripts/build-runtime.sh`) contains a Python 3.12 interpreter (PSF License), Ollama (MIT),
Chromium's headless shell through Playwright (BSD-style, with its own third-party notices), and the Python packages
pinned in `scripts/runtime-requirements.txt`, among them `anthropic` (MIT), `openai` (Apache-2.0), `mlx-audio` (MIT),
`notebooklm-py` (MIT), `playwright` (Apache-2.0), `av`/PyAV (BSD-3-Clause, with FFmpeg under LGPL), `pypdf`
(BSD-3-Clause), and `numpy` (BSD-3-Clause and others). Each package's license ships inside its folder in the runtime.

Models that Ollama downloads (for example Qwen or Gemma) come with their own licenses, shown by Ollama.
