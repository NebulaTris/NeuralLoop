#!/usr/bin/env bash
# Build NeuralLoop's self-contained runtime: a relocatable Python with the pipeline and every provider,
# Rumik's MLX libraries, the NotebookLM library, and Ollama. The Mac app ships this folder inside
# NeuralLoop.app/Contents/Resources/runtime, so people install nothing else. Models (the local text model,
# the recall model, Rumik's voices) are downloaded the first time the Mac's own AI is used (`neuralloop --setup`).
#
# Usage: scripts/build-runtime.sh [OUT_DIR]      (default: build/runtime)
#        scripts/build-runtime.sh --stamp         (print the stamp for the current sources and exit)
#
# What is downloaded, and how it is pinned:
# - uv itself is not downloaded here: it must already be installed, at UV_MIN_VERSION or newer (checked below).
# - Python: an exact patch version from uv's relocatable builds (PYTHON_VERSION), fetched and checked by uv.
# - Python packages: scripts/runtime-requirements.txt, installed with --require-hashes. To refresh it
#   (after changing pipeline/pyproject.toml, or to take updates), run from the repo root:
#     MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile pipeline/pyproject.toml --extra anthropic \
#       --extra openai --extra rumik --extra notebooklm --extra video --python-version 3.12.14 \
#       --python-platform aarch64-apple-darwin --generate-hashes --upgrade -o scripts/runtime-requirements.txt
#   Keep --python-version equal to PYTHON_VERSION. MACOSX_DEPLOYMENT_TARGET matches the app's (14.0): without
#   it uv assumes an older macOS, can't use current MLX wheels, and falls back to an old mlx-audio with torch.
#   Every package must have a wheel (--only-binary below), so sdist build tools are never fetched unpinned.
# - Chromium (explainer videos): the chrome-headless-shell build the locked Playwright version names (plus
#   Playwright's small ffmpeg), downloaded by Playwright itself over HTTPS. Playwright checks no hash, so this script
#   does: every installed file must match BROWSERS_SHA256, a SHA-256 over the whole installed tree (paths, contents,
#   executable bits, symlinks). After changing the Playwright version, install it once and record the new hash:
#     PLAYWRIGHT_BROWSERS_PATH=/tmp/nl-browsers <runtime python> -m playwright install chromium --only-shell
#     scripts/build-runtime.sh --browsers-hash /tmp/nl-browsers      (paste the result into BROWSERS_SHA256)
# - Ollama: OLLAMA_VERSION with the SHA-256 of ollama-darwin.tgz from that release's sha256sum.txt
#   (https://github.com/ollama/ollama/releases/download/v<version>/sha256sum.txt), and the binary's
#   Developer ID signature must belong to Ollama's team (OLLAMA_TEAM_ID). Update all three together.
#
# Licences: NeuralLoop's LICENSE, NOTICE.md, and every text in licenses/ are copied into OUT/licenses, so the
# runtime carries the notices for what it bundles (FFmpeg/x264/x265 and the codec libraries inside PyAV, the
# libraries the relocatable Python links in, Ollama, the fonts…). After changing a pinned version, check NOTICE.md's
# lists against what actually ships (otool -L on av/.dylibs, the Python's libpython).
#
# The runtime is built in a temporary folder next to OUT and moved into place only after every check
# passes. OUT/.stamp records a hash of the inputs (pipeline sources, the lock file, this script), so
# scripts/package-mac.sh can tell when the runtime is stale.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_VERSION="3.12.14"
OLLAMA_VERSION="0.32.14"
OLLAMA_SHA256="c7e8b91485943785bc6d295d96551e971ec94c6829d0d6b3500366942dc50cd1"
OLLAMA_TEAM_ID="3MU9H2V9Y9" # Developer ID Application: Infra Technologies, Inc (Ollama)
# Playwright 1.63.0's chromium_headless_shell-1243 (Chrome 153.0.8010.12) and ffmpeg-1011, as installed (--browsers-hash).
BROWSERS_SHA256="c150dbd584908ae7e21bbe641934776f8ddfd041ed9df5f6965d471b5253bb6a"
UV_MIN_VERSION="0.12.0"     # the oldest uv this script has been tested with
LOCK="$ROOT/scripts/runtime-requirements.txt"
MARKER=".neuralloop-runtime" # written into every runtime; OUT is only ever replaced when it has one

# A hash of everything the runtime is built from. Keep in sync with what is copied below.
runtime_stamp() {
  (
    cd "$ROOT"
    {
      find pipeline/nl_book.py pipeline/neuralloop_books pipeline/sample -type f \
        -not -path '*/__pycache__/*' -not -name '*.pyc'
      find licenses -type f
      printf '%s\n' scripts/runtime-requirements.txt scripts/build-runtime.sh LICENSE NOTICE.md
    } | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1
  )
}

# One SHA-256 over an installed folder: each file's path, executable bit and content hash, and each symlink's target.
# Playwright's own bookkeeping (marker files, and .links/, which records the temporary build path and is deleted
# after the check) is left out.
tree_sha256() {
  (
    cd "$1"
    find . \( -type f -o -type l \) -not -path './.links/*' \
      -not -name INSTALLATION_COMPLETE -not -name DEPENDENCIES_VALIDATED -print0 |
      LC_ALL=C sort -z | while IFS= read -r -d '' f; do
      if [[ -L "$f" ]]; then
        printf 'link %s %s\n' "$f" "$(readlink "$f")"
      else
        mode="-"
        [[ -x "$f" ]] && mode="x"
        printf 'file %s %s %s\n' "$f" "$mode" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
      fi
    done | shasum -a 256 | cut -d' ' -f1
  )
}

if [[ "${1:-}" == "--stamp" ]]; then
  runtime_stamp
  exit 0
fi
if [[ "${1:-}" == "--browsers-hash" ]]; then
  if [[ ! -d "${2:-}" ]]; then
    echo "Usage: scripts/build-runtime.sh --browsers-hash PLAYWRIGHT_BROWSERS_PATH" >&2
    exit 1
  fi
  tree_sha256 "$2"
  exit 0
fi

OUT="${1:-$ROOT/build/runtime}"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"

if [[ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]]; then
  echo "NeuralLoop's runtime is built for Macs with Apple silicon (Rumik runs on MLX)." >&2
  exit 1
fi
if [[ ! -x "$UV" ]]; then
  echo "uv is needed to fetch a relocatable Python: https://docs.astral.sh/uv/" >&2
  exit 1
fi
UV_VERSION="$("$UV" --version | awk '{print $2}')"
if [[ "$(printf '%s\n%s\n' "$UV_MIN_VERSION" "$UV_VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != "$UV_MIN_VERSION" ]]; then
  echo "uv $UV_VERSION is too old; this script needs uv $UV_MIN_VERSION or newer (uv self update)." >&2
  exit 1
fi
if [[ ! -f "$LOCK" ]]; then
  echo "The package lock $LOCK is missing (see the comment at the top of this script)." >&2
  exit 1
fi

# Only ever replace a folder this script made (or an empty or missing one): OUT is deleted below.
if [[ -e "$OUT" ]]; then
  if [[ ! -d "$OUT" ]]; then
    echo "$OUT exists and is not a folder; choose another output folder." >&2
    exit 1
  fi
  # Runtimes built before the marker existed are recognised by their launcher.
  if [[ -n "$(ls -A "$OUT")" && ! -f "$OUT/$MARKER" ]] &&
    ! grep -qs "NeuralLoop's pipeline with the bundled Python" "$OUT/bin/neuralloop"; then
    echo "$OUT isn't empty and wasn't made by this script; refusing to replace it." >&2
    exit 1
  fi
fi

OUT_PARENT="$(dirname "$OUT")"
mkdir -p "$OUT_PARENT"
OUT="$(cd "$OUT_PARENT" && pwd)/$(basename "$OUT")"
STAMP="$(runtime_stamp)"

# Build next to OUT (same volume, so the final move is a rename) and clean up on any failure.
WORK="$(mktemp -d "$OUT.building.XXXXXX")"
DL="$(mktemp -d)"
OLD=""
cleanup() {
  rm -rf "$WORK" "$DL"
  if [[ -n "$OLD" ]]; then
    if [[ -e "$OUT" ]]; then
      rm -rf "$OLD"
    elif mv "$OLD" "$OUT"; then # the swap didn't finish: put the old runtime back rather than lose both
      echo "The new runtime couldn't be moved into place; the old one is back at $OUT." >&2
    else
      echo "The new runtime couldn't be moved into place; the old one is still at $OLD." >&2
    fi
  fi
}
trap cleanup EXIT
mkdir -p "$WORK"/{bin,pipeline,ollama}

echo "• Python $PYTHON_VERSION (relocatable build)"
"$UV" python install "$PYTHON_VERSION" --install-dir "$DL/python" --quiet
# The real folder is versioned (cpython-3.12.14-…); shorter names next to it are only symlinks.
PYTHON_DIR="$(find "$DL/python" -maxdepth 1 -type d -name "cpython-$PYTHON_VERSION-*" | head -1)"
if [[ -z "$PYTHON_DIR" ]]; then
  echo "uv didn't install Python $PYTHON_VERSION." >&2
  exit 1
fi
mv "$PYTHON_DIR" "$WORK/python"
PY="$WORK/python/bin/python3"
"$PY" -c "import platform, sys; sys.exit(platform.python_version() != '$PYTHON_VERSION')"
find "$WORK/python/lib" -name EXTERNALLY-MANAGED -delete # this Python is ours alone

echo "• Pipeline dependencies (every provider, Rumik, NotebookLM), hash-checked"
# The pipeline itself isn't installed: its source is copied below and run by the launcher.
"$PY" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary :all: -r "$LOCK"

echo "• Pipeline source"
cp "$ROOT/pipeline/nl_book.py" "$WORK/pipeline/"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$ROOT/pipeline/neuralloop_books" "$ROOT/pipeline/sample" \
  "$WORK/pipeline/"

echo "• Chromium for rendering explainer videos (checksum verified)"
PLAYWRIGHT_BROWSERS_PATH="$WORK/browsers" "$PY" -m playwright install chromium --only-shell >/dev/null
GOT="$(tree_sha256 "$WORK/browsers")"
if [[ "$GOT" != "$BROWSERS_SHA256" ]]; then
  echo "Chromium as installed by Playwright doesn't match its pinned checksum (expected $BROWSERS_SHA256, got $GOT)." >&2
  echo "If the Playwright version changed on purpose, record the new hash (see the top of this script)." >&2
  exit 1
fi
# .links/ is Playwright's install bookkeeping (left out of the hash above): it holds the build folder's absolute path,
# which would ship the builder's home folder in the DMG. Playwright reads it only while installing or uninstalling
# browsers (and an install writes its own link first), never to launch one.
rm -rf "$WORK/browsers/.links"

echo "• Licences"
mkdir -p "$WORK/licenses"
cp "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$ROOT"/licenses/* "$WORK/licenses/"

echo "• Ollama $OLLAMA_VERSION (checksum and signature verified)"
curl -fsSL --retry 3 -o "$DL/ollama-darwin.tgz" \
  "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-darwin.tgz"
GOT="$(shasum -a 256 "$DL/ollama-darwin.tgz" | cut -d' ' -f1)"
if [[ "$GOT" != "$OLLAMA_SHA256" ]]; then
  echo "Ollama's download doesn't match its pinned checksum (expected $OLLAMA_SHA256, got $GOT)." >&2
  exit 1
fi
tar -xzf "$DL/ollama-darwin.tgz" -C "$WORK/ollama"
test -x "$WORK/ollama/ollama"
# The TeamIdentifier codesign prints is only the leaf certificate's OU, which a self-signed certificate can claim too:
# require a Developer ID chain to Apple's root with Ollama's team in it.
DEVELOPER_ID='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
DEVELOPER_ID+=" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
DEVELOPER_ID+=" and certificate leaf[subject.OU] = \"$OLLAMA_TEAM_ID\""
if ! codesign --verify --strict -R="$DEVELOPER_ID" "$WORK/ollama/ollama"; then
  TEAM="$(codesign -dv --verbose=4 "$WORK/ollama/ollama" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  echo "Ollama's binary isn't signed with Ollama's Developer ID ($OLLAMA_TEAM_ID); it says team '$TEAM'." >&2
  exit 1
fi

cat >"$WORK/bin/neuralloop" <<'LAUNCHER'
#!/bin/sh
# NeuralLoop's pipeline with the bundled Python and Ollama. Everything the app runs goes through here.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export NEURALLOOP_OLLAMA="${NEURALLOOP_OLLAMA:-$HERE/ollama/ollama}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HERE/browsers}"
# Keep the app bundle untouched (its signature seals it): compiled Python goes to the person's caches.
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/Library/Caches/NeuralLoop/pycache}"
export PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1
# Only the bundled packages: a PYTHONPATH or PYTHONHOME from the person's shell must not replace them.
unset PYTHONPATH PYTHONHOME
exec "$HERE/python/bin/python3" "$HERE/pipeline/nl_book.py" "$@"
LAUNCHER
chmod +x "$WORK/bin/neuralloop"

echo "• Checks"
"$PY" -c "import anthropic, openai, notebooklm, mlx_audio, av, playwright, pypdf"
PYTHONPYCACHEPREFIX="$DL/pycache" "$WORK/bin/neuralloop" --dry-run --no-open --out "$DL/smoke" >/dev/null
test -f "$DL/smoke/book.json"
# One test per line: with set -e, a failure early in an && list would not stop the script.
for f in NOTICE.md GPL-2.0.txt Ollama-MIT.txt Apache-2.0.txt; do
  test -f "$WORK/licenses/$f"
done
test ! -e "$WORK/browsers/.links"
find "$WORK" -name __pycache__ -type d -prune -exec rm -rf {} +

echo "$STAMP" >"$WORK/.stamp"
echo "NeuralLoop runtime built by scripts/build-runtime.sh; safe to delete." >"$WORK/$MARKER"

# Swap it in: the old runtime is renamed aside first, so OUT is never half-written. If the second move fails (or
# the script is stopped between the two), cleanup moves the old runtime back.
if [[ -e "$OUT" ]]; then
  OLD="$(mktemp -d "$OUT.old.XXXXXX")"
  rmdir "$OLD"
  mv "$OUT" "$OLD"
fi
mv "$WORK" "$OUT"

echo "Runtime ready: $OUT ($(du -sh "$OUT" | cut -f1))"
