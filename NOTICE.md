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

- **Python 3.12.14** (PSF License; its `LICENSE.txt` ships in `runtime/python/lib/python3.12/`), the relocatable build
  from `python-build-standalone` release 20260924 (https://github.com/astral-sh/python-build-standalone/tree/20260924).
  See "Inside the bundled Python" below for the libraries built into it.
- **Ollama 0.32.14** (MIT, `licenses/Ollama-MIT.txt`), Ollama's own signed build. It includes **llama.cpp/ggml** (build
  b10434, MIT, `licenses/llama.cpp-ggml-MIT.txt`) and **MLX** with **mlx-c** (MIT, `licenses/MLX-MIT.txt`,
  `licenses/mlx-c-MIT.txt`).
- **Chromium's headless shell** 153.0.8010.12 through Playwright (BSD-style, with its own third-party notices in
  `LICENSE.headless_shell` next to the binary) and Playwright's small **ffmpeg** build (LGPL-2.1, `COPYING.LGPLv2.1` next
  to it; see "Playwright's ffmpeg" below). NeuralLoop uses Chromium only to draw explainer frames.
- The Python packages pinned in `scripts/runtime-requirements.txt`, among them `anthropic` (MIT), `openai` (Apache-2.0),
  `mlx`/`mlx-metal` (MIT), `mlx-audio` (MIT), `notebooklm-py` (MIT), `playwright` (Apache-2.0), `av`/PyAV (BSD-3-Clause,
  `licenses/PyAV-BSD-3-Clause.txt`; see below), `pypdf` (BSD-3-Clause), and `numpy` (BSD-3-Clause and others). Each
  package's license ships inside its folder in the runtime, except `tokenizers` 0.23.2 (Hugging Face, Apache-2.0),
  whose wheel carries none: its text is `licenses/Apache-2.0.txt`.

### Inside the bundled Python

The relocatable Python links these libraries into `libpython3.12.dylib` (or ships them next to it). Each one's licence
text is in `licenses/`; the exact sources are listed, with their SHA-256, in python-build-standalone's
`pythonbuild/downloads.json` at release 20260924.

| Library | Version | License | Text |
|---|---|---|---|
| OpenSSL (Copyright The OpenSSL Project Authors) | 3.5.8 | Apache-2.0 | `licenses/Apache-2.0.txt` |
| SQLite | 3.53.1 | Public domain | `licenses/SQLite-public-domain.txt` |
| libffi (Copyright Anthony Green, Red Hat, Inc and others) | 3.4.8 | MIT | `licenses/libffi-MIT.txt` |
| liblzma from XZ Utils | 5.8.4 | 0BSD | `licenses/xz-liblzma-0BSD.txt` |
| bzip2 (Copyright Julian R Seward) | 1.0.8 | bzip2 (BSD-style) | `licenses/bzip2.txt` |
| mpdecimal (Copyright Stefan Krah) | 4.0.0 | BSD-2-Clause | `licenses/mpdecimal-BSD-2-Clause.txt` |
| Expat (Copyright Thai Open Source Software Center Ltd, Clark Cooper, Expat maintainers) | 2.8.5 | MIT | `licenses/expat-MIT.txt` |
| libuuid (Copyright Theodore Ts'o) | 1.0.3 | BSD-3-Clause | `licenses/libuuid-BSD-3-Clause.txt` |
| Tcl and Tk (`libtcl9.0.dylib`, `libtcl9tk9.0.dylib`, with `itcl` 4.3.8 and `thread` 3.0.6) | 9.0.4 | Tcl/Tk licence (BSD-style) | `licenses/Tcl-Tk.txt` |

zlib, ncurses and libedit come from macOS itself (`/usr/lib`) and aren't shipped.

### FFmpeg, x264 and x265

PyAV 18.1.0's macOS wheel (the `av` package in the runtime) carries its own build of FFmpeg in `av/.dylibs`, made by
PyAV's `pyav-ffmpeg` 8.1.2-1 build scripts. Exactly what is in it:

| Library | Version | License | Corresponding source |
|---|---|---|---|
| FFmpeg (`libavcodec.62`, `libavformat.62`, `libavutil.60`, `libavfilter.11`, `libavdevice.62`, `libswscale.9`, `libswresample.6`) | 8.1.2, configured with `--enable-version3` | LGPL-3.0-or-later (`licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt`, `licenses/FFmpeg-LICENSE.md`) | https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz |
| x264 (`libx264.165`) | commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | **GPL-2.0-or-later** (`licenses/GPL-2.0.txt`) | https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2 |
| x265 (`libx265.216`) | 4.2 | **GPL-2.0-or-later** (`licenses/GPL-2.0.txt`) | https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.2.tar.gz |
| dav1d (`libdav1d.7`; Copyright VideoLAN and dav1d authors) | 1.5.3 | BSD-2-Clause (`licenses/dav1d-BSD-2-Clause.txt`) | https://code.videolan.org/videolan/dav1d/-/archive/1.5.3/dav1d-1.5.3.tar.bz2 |
| libvpx (`libvpx.12`; Copyright The WebM Project authors) | 1.16.0 | BSD-3-Clause and Google's patent grant (`licenses/libvpx-BSD-3-Clause.txt`) | https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz |
| libwebp with libsharpyuv and libwebpmux (`libwebp.7`, `libsharpyuv.0`, `libwebpmux.3`; Copyright Google Inc.) | 1.6.0 | BSD-3-Clause and Google's patent grant (`licenses/libwebp-BSD-3-Clause.txt`) | https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz |
| Opus (`libopus.0`; Copyright Xiph.Org, Skype Limited, Octasic and others) | 1.6.1 | BSD-3-Clause (`licenses/Opus-BSD-3-Clause.txt`) | https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz |
| SVT-AV1 (`libSvtAv1Enc.4`; Copyright Alliance for Open Media) | 4.1.0 | BSD-3-Clause-Clear (`licenses/SVT-AV1-BSD-3-Clause-Clear.txt`) and the Alliance for Open Media Patent License 1.0 (`licenses/SVT-AV1-AOM-Patent-License-1.0.txt`) | https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.1.0/SVT-AV1-v4.1.0.tar.bz2 |
| opencore-amr (`libopencore-amrnb.0`, `libopencore-amrwb.0`; Copyright PacketVideo, Martin Storsjo) | 0.1.6 | Apache-2.0 (`licenses/Apache-2.0.txt`; the release has no NOTICE file) | https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz |
| LAME (`libmp3lame.0`; Copyright The LAME Project and others) | 3.100 | **LGPL-2.0-or-later** (`licenses/LAME-LGPL-2.0.txt`) | http://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz |
| PyAV | 18.1.0 | BSD-3-Clause | https://github.com/PyAV-Org/PyAV/tree/v18.1.0 |
| Build scripts and patches for the above | `pyav-ffmpeg` 8.1.2-1 | BSD-3-Clause | https://github.com/PyAV-Org/pyav-ffmpeg/tree/8.1.2-1 (`scripts/pkg.py` lists every source and its SHA-256; `patches/` holds the changes) |

FFmpeg is linked there with x264 and x265, which are GPL-2.0-or-later. PyAV's build patches FFmpeg's `configure` so it
reports "LGPL version 3 or later", but because `libavcodec` links x264 and x265, those FFmpeg binaries as shipped are
covered by the GNU GPL (GPL-3.0, the version compatible with both licences). The other libraries in the table are
linked into the same build as separate libraries, each under its own licence.

NeuralLoop's own code doesn't link these libraries. The pipeline is Python that imports the separate PyAV module at
run time, and it asks for the Mac's own H.264 encoder (VideoToolbox, part of macOS) first; x264 is used only as a last
resort on a machine where VideoToolbox can't start (`pipeline/neuralloop_books/video.py`).

### Playwright's ffmpeg

Playwright 1.63.0 installs its own small ffmpeg next to Chromium (`runtime/browsers/ffmpeg-1011/ffmpeg-mac`,
Playwright's build 1011; Playwright uses it only to record videos, which NeuralLoop doesn't do). It is FFmpeg
**n7.0.1** (LGPL-2.1-or-later: it is configured without any GPL or nonfree parts, `COPYING.LGPLv2.1` next to it),
statically linked with libvpx 1.14.1 (BSD-3-Clause, `licenses/libvpx-BSD-3-Clause.txt`; the same licence as the
1.16.0 above) and zlib 1.3.1 (Zlib licence), as the binary itself reports.

- FFmpeg source: https://ffmpeg.org/releases/ffmpeg-7.0.1.tar.xz (tag `n7.0.1`). The exact `configure` options it was
  built with are printed by `ffmpeg-mac -version`.
- libvpx: https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz; zlib:
  https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz.
- Build scripts: Playwright's `browser_patches/ffmpeg` (https://github.com/microsoft/playwright/tree/a07a4a25a26e2fa6a976fb2ff174f25b24414da6/browser_patches/ffmpeg).
  They were public up to build 1007; Microsoft has built later revisions, 1011 among them, in its own build
  infrastructure, and their scripts aren't published.

**Source code offer.** The links above are the exact upstream source releases the FFmpeg, x264, x265, LAME and other
binaries described in this file were built from. If any of them stops working, or for Playwright's ffmpeg (build
1011), whose own build scripts aren't public, open an issue on this repository and we will provide a complete copy of
the corresponding source for those binaries, at no more than the cost of providing it, for at least three years after
we last distributed a runtime containing them.

Models that Ollama downloads (for example Qwen or Gemma) come with their own licenses, shown by Ollama.
