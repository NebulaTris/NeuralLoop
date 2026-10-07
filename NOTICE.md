# Third-party notices

NeuralLoop's own code is licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`). It builds on, and the
packaged Mac app bundles, the components below, each under its own license. Where a component restricts use, that
restriction applies to anyone using the component through NeuralLoop.

The licence texts referred to here are in `licenses/`. The packaged app carries `LICENSE`, this file, and `licenses/` in
`NeuralLoop.app/Contents/Resources`, and its runtime carries them again in `Contents/Resources/runtime/licenses`.

## Components with restrictions to know about

| Component | Used for | License | What it means |
|---|---|---|---|
| **Rumik OSS-1** voices (`rumik-ai/rumik-oss-1-mlx-4bit`, `-8bit`), downloaded on first use | Podcast and explainer narration made on your Mac | **CC BY-NC 4.0** | **Non-commercial use only.** Anyone selling NeuralLoop, or using it commercially, needs a separate licence from Rumik or a different voice engine. |
| **Google NotebookLM**, through `notebooklm-py` | The default way study material is made | Google's terms of service; `notebooklm-py` is MIT | `notebooklm-py` uses unofficial interfaces that can change at any time. Check Google's terms before any commercial use. |
| **FFmpeg with x264 and x265**, inside PyAV | Encoding explainer videos | FFmpeg LGPL-3.0-or-later; x264 and x265 **GPL-2.0-or-later** | See "FFmpeg, x264 and x265" below. |

## Nudge sounds

`apple/App/Resources/NeuralLoop-sad-violin.caf`, `-sad-meow.caf` and `-fahhh.caf` (Silly mode's sounds) were made by
NeuralLoop's author and are covered by this repository's licence, like the rest of NeuralLoop.

## Fonts (bundled in the app and in the pipeline's explainer videos)

| Font | License | Text |
|---|---|---|
| Fredoka (`fredoka-400/500/600`) | SIL Open Font License 1.1 | `licenses/Fredoka-OFL.txt` |
| Atkinson Hyperlegible (`atkinson-400/700`) | SIL Open Font License 1.1 | `licenses/AtkinsonHyperlegible-OFL.txt` |

## Bundled in the Mac app's runtime

The runtime (built by `scripts/build-runtime.sh`) contains:

- **Python 3.12.14** (PSF License; its `LICENSE.txt` ships in `runtime/python/lib/python3.12/`).
- **Ollama 0.32.14** (MIT, `licenses/Ollama-MIT.txt`), Ollama's own signed build. It includes **llama.cpp/ggml** (build
  b10434, MIT, `licenses/llama.cpp-ggml-MIT.txt`) and **MLX** with **mlx-c** (MIT, `licenses/MLX-MIT.txt`,
  `licenses/mlx-c-MIT.txt`).
- **Chromium's headless shell** 153.0.8010.12 through Playwright (BSD-style, with its own third-party notices in
  `LICENSE.headless_shell` next to the binary) and Playwright's small **ffmpeg** build (LGPL-2.1, `COPYING.LGPLv2.1` next
  to it). NeuralLoop uses Chromium only to draw explainer frames.
- The Python packages pinned in `scripts/runtime-requirements.txt`, among them `anthropic` (MIT), `openai` (Apache-2.0),
  `mlx`/`mlx-metal` (MIT), `mlx-audio` (MIT), `notebooklm-py` (MIT), `playwright` (Apache-2.0), `av`/PyAV (BSD-3-Clause,
  `licenses/PyAV-BSD-3-Clause.txt`; see below), `pypdf` (BSD-3-Clause), and `numpy` (BSD-3-Clause and others). Each
  package's license ships inside its folder in the runtime.

### FFmpeg, x264 and x265

PyAV 18.1.0's macOS wheel (the `av` package in the runtime) carries its own build of FFmpeg in `av/.dylibs`, made by
PyAV's `pyav-ffmpeg` 8.1.2-1 build scripts. Exactly what is in it:

| Library | Version | License | Corresponding source |
|---|---|---|---|
| FFmpeg (`libavcodec.62`, `libavformat.62`, `libavutil.60`, `libavfilter.11`, `libavdevice.62`, `libswscale.9`, `libswresample.6`) | 8.1.2, configured with `--enable-version3` | LGPL-3.0-or-later (`licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt`, `licenses/FFmpeg-LICENSE.md`) | https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz |
| x264 (`libx264.165`) | commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | **GPL-2.0-or-later** (`licenses/GPL-2.0.txt`) | https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2 |
| x265 (`libx265.216`) | 4.2 | **GPL-2.0-or-later** (`licenses/GPL-2.0.txt`) | https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.2.tar.gz |
| PyAV | 18.1.0 | BSD-3-Clause | https://github.com/PyAV-Org/PyAV/tree/v18.1.0 |
| Build scripts and patches for the above | `pyav-ffmpeg` 8.1.2-1 | BSD-3-Clause | https://github.com/PyAV-Org/pyav-ffmpeg/tree/8.1.2-1 (`scripts/pkg.py` lists every source and its SHA-256; `patches/` holds the changes) |

FFmpeg is linked there with x264 and x265, which are GPL-2.0-or-later. PyAV's build patches FFmpeg's `configure` so it
reports "LGPL version 3 or later", but because `libavcodec` links x264 and x265, those FFmpeg binaries as shipped are
covered by the GNU GPL (GPL-3.0, the version compatible with both licences). The same FFmpeg build also links dav1d
(BSD-2-Clause), LAME (LGPL-2.0-or-later), opencore-amr (Apache-2.0), Opus, libvpx, libwebp (BSD-3-Clause), and SVT-AV1
(BSD-3-Clause-Clear with the AOM patent licence); `scripts/pkg.py` above names each exact source.

NeuralLoop's own code doesn't link these libraries. The pipeline is Python that imports the separate PyAV module at
run time, and it asks for the Mac's own H.264 encoder (VideoToolbox, part of macOS) first; x264 is used only as a last
resort on a machine where VideoToolbox can't start (`pipeline/neuralloop_books/video.py`).

**Source code offer.** The links above are the exact upstream source releases these binaries were built from. If any of
them stops working, open an issue on this repository and we will provide a complete copy of the corresponding source for
those binaries, at no more than the cost of providing it, for at least three years after we last distributed a
runtime containing them.

Models that Ollama downloads (for example Qwen or Gemma) come with their own licenses, shown by Ollama.
