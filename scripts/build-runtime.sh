#!/usr/bin/env bash
# Build NeuralLoop's self-contained runtime: a relocatable Python with the pipeline and every provider,
# Rumik's MLX libraries, the NotebookLM library, and Ollama. The Mac app ships this folder inside
# NeuralLoop.app/Contents/Resources/runtime, so people install nothing else. Models (the local text model,
# the recall model, Rumik's voices) are downloaded on first launch by `neuralloop --setup`.
#
# Usage: scripts/build-runtime.sh [OUT_DIR]      (default: build/runtime)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/runtime}"
PYTHON_VERSION="3.12"
OLLAMA_VERSION="${OLLAMA_VERSION:-0.32.14}"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"

if [[ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]]; then
  echo "NeuralLoop's runtime is built for Macs with Apple silicon (Rumik runs on MLX)." >&2
  exit 1
fi
if [[ ! -x "$UV" ]]; then
  echo "uv is needed to fetch a relocatable Python: https://docs.astral.sh/uv/" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"/{bin,pipeline,ollama}

echo "• Python $PYTHON_VERSION (relocatable build)"
"$UV" python install "$PYTHON_VERSION" --install-dir "$OUT/.python-download" --quiet
# The real folder is versioned (cpython-3.12.14-…); cpython-3.12-… next to it is only a symlink.
PYTHON_DIR="$(find "$OUT/.python-download" -maxdepth 1 -type d -name "cpython-$PYTHON_VERSION.*" | head -1)"
mv "$PYTHON_DIR" "$OUT/python"
rm -rf "$OUT/.python-download"
PY="$OUT/python/bin/python3"
find "$OUT/python/lib" -name EXTERNALLY-MANAGED -delete  # this Python is ours alone

echo "• Pipeline dependencies (every provider, Rumik, NotebookLM)"
"$PY" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
  "$ROOT/pipeline[anthropic,openai,rumik,notebooklm,video]"
"$PY" -m pip uninstall --quiet --yes neuralloop-books-pipeline  # the source is copied below instead

echo "• Pipeline source"
cp "$ROOT/pipeline/nl_book.py" "$OUT/pipeline/"
rsync -a --exclude __pycache__ "$ROOT/pipeline/neuralloop_books" "$ROOT/pipeline/sample" "$OUT/pipeline/"
mkdir -p "$OUT/pipeline/site"
cp "$ROOT"/pipeline/site/{index.html,styles.css,app.js,pip-poses.js} "$OUT/pipeline/site/"

echo "• Chromium for rendering explainer videos"
PLAYWRIGHT_BROWSERS_PATH="$OUT/browsers" "$PY" -m playwright install chromium --only-shell >/dev/null

echo "• Ollama $OLLAMA_VERSION"
curl -fsSL "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-darwin.tgz" \
  | tar -xz -C "$OUT/ollama"
test -x "$OUT/ollama/ollama"

cat > "$OUT/bin/neuralloop" <<'LAUNCHER'
#!/bin/sh
# NeuralLoop's pipeline with the bundled Python and Ollama. Everything the app runs goes through here.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export NEURALLOOP_OLLAMA="${NEURALLOOP_OLLAMA:-$HERE/ollama/ollama}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HERE/browsers}"
# Keep the app bundle untouched (its signature seals it): compiled Python goes to the person's caches.
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/Library/Caches/NeuralLoop/pycache}"
export PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1
exec "$HERE/python/bin/python3" "$HERE/pipeline/nl_book.py" "$@"
LAUNCHER
chmod +x "$OUT/bin/neuralloop"

echo "• Smoke test"
"$OUT/bin/neuralloop" --dry-run --no-open --out "$OUT/.smoke" >/dev/null
test -f "$OUT/.smoke/book-data.js"
rm -rf "$OUT/.smoke"
"$PY" -c "import anthropic, openai, notebooklm, mlx_audio, av, playwright" 2>/dev/null

echo "Runtime ready: $OUT ($(du -sh "$OUT" | cut -f1))"
