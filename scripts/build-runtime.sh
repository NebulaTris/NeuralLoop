#!/usr/bin/env bash
# Build NeuralLoop's self-contained runtime: a relocatable Python with the pipeline and every provider,
# Rumik's MLX libraries, the NotebookLM library, and Ollama. The Mac app ships this folder inside
# NeuralLoop.app/Contents/Resources/runtime, so people install nothing else. Models (the local text model,
# the recall model, Rumik's voices) are downloaded on first launch by `neuralloop --setup`.
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
# - Chromium (explainer videos): the build the locked Playwright version names, downloaded by Playwright itself.
#   Its version follows the lock, but this script has no checksum of its own for it.
# - Ollama: OLLAMA_VERSION with the SHA-256 of ollama-darwin.tgz from that release's sha256sum.txt
#   (https://github.com/ollama/ollama/releases/download/v<version>/sha256sum.txt), and the binary's
#   Developer ID signature must belong to Ollama's team (OLLAMA_TEAM_ID). Update all three together.
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
      printf '%s\n' scripts/runtime-requirements.txt scripts/build-runtime.sh
    } | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1
  )
}

if [[ "${1:-}" == "--stamp" ]]; then
  runtime_stamp
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

echo "• Chromium for rendering explainer videos"
PLAYWRIGHT_BROWSERS_PATH="$WORK/browsers" "$PY" -m playwright install chromium --only-shell >/dev/null

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
