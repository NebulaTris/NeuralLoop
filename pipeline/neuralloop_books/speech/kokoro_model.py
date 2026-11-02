"""Kokoro-82M (https://huggingface.co/hexgrad/Kokoro-82M, Apache-2.0) run with ONNX Runtime: Kokoro's phonemes
in, 24 kHz audio out. Only onnxruntime and numpy; the phonemes come from `espeak.py`.

How the model is driven follows kokoro-onnx (MIT, Copyright 2025 thewh1teagle,
https://github.com/thewh1teagle/kokoro-onnx): the tokens padded with 0 at both ends, the voice's style row for
that many tokens, at most 510 phonemes a pass, each pass's silence trimmed and a short pause put back between
passes. The ONNX files are kokoro-onnx's `model-files-v1.0` release.
"""

import json
import re
from functools import lru_cache
from pathlib import Path

import numpy as np

RATE = 24_000
LIMIT = 510  # phonemes the model takes in one pass
SENTENCE_MARKS = ".!?…"
CLAUSE_MARKS = ",;:"
SENTENCE_PAUSE = 0.25
CLAUSE_PAUSE = 0.1

# Where a long run of phonemes may be cut, least disruptive first; a mark stays with what's before it.
_CUTS = (
    re.compile(rf"(?<=[{re.escape(SENTENCE_MARKS)}])\s+"),
    re.compile(rf"(?<=[{re.escape(CLAUSE_MARKS)}])\s+"),
    re.compile(r"\s+"),
)


@lru_cache(maxsize=1)
def vocab() -> dict[str, int]:
    path = Path(__file__).resolve().parents[1] / "assets" / "kokoro-vocab.json"
    return json.loads(path.read_text(encoding="utf-8"))["vocab"]


def tokens(phonemes: str, table: dict[str, int]) -> list[int]:
    return [table[p] for p in phonemes if p in table]


def _pieces(phonemes: str, limit: int, level: int = 0) -> list[str]:
    if len(phonemes) <= limit:
        return [phonemes] if phonemes else []
    for depth in range(level, len(_CUTS)):
        parts = _CUTS[depth].split(phonemes)
        if len(parts) > 1:
            return [piece for part in parts for piece in _pieces(part.strip(), limit, depth + 1)]
    return [phonemes[i : i + limit] for i in range(0, len(phonemes), limit)]


def batches(phonemes: str, limit: int = LIMIT) -> list[str]:
    """The phonemes in passes of at most `limit`: cut after sentences, then clauses, then between words, and
    only as a last resort inside one; neighbouring pieces share a pass while they fit."""
    out: list[str] = []
    for piece in _pieces(" ".join(phonemes.split()), limit):
        if out and len(out[-1]) + 1 + len(piece) <= limit:
            out[-1] = f"{out[-1]} {piece}"
        else:
            out.append(piece)
    return out


def trim(audio: np.ndarray, top_db: float = 60, frame: int = 2048, hop: int = 512) -> np.ndarray:
    """The audio without the near-silence at either end: frames more than `top_db` below the loudest."""
    if audio.size == 0:
        return audio
    padded = np.pad(audio.astype(np.float64), frame // 2)
    count = 1 + max(0, (len(padded) - frame) // hop)
    energy = np.concatenate([[0.0], np.cumsum(padded**2)])
    starts = np.arange(count) * hop
    rms = np.sqrt((energy[starts + frame] - energy[starts]) / frame)
    if rms.max() <= 0:
        return audio[:0]
    loud = np.flatnonzero(20 * np.log10(np.maximum(rms, 1e-10) / rms.max()) > -top_db)
    return audio[loud[0] * hop : min(len(audio), (loud[-1] + 1) * hop)]


def pause_after(phonemes: str) -> float:
    mark = phonemes.rstrip()[-1:]
    if mark and mark in SENTENCE_MARKS:
        return SENTENCE_PAUSE
    if mark and mark in CLAUSE_MARKS:
        return CLAUSE_PAUSE
    return 0.0


class KokoroModel:
    def __init__(self, model_path: str | Path, voices_path: str | Path):
        import onnxruntime

        self.session = onnxruntime.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
        with np.load(voices_path) as stored:  # every voice's style table: (510, 1, 256)
            self.voices = {name: stored[name] for name in stored.files}
        self.table = vocab()

    def create(self, phonemes: str, voice: str, speed: float) -> np.ndarray:
        styles = self.voices.get(voice)
        if styles is None:
            raise ValueError(f"Kokoro has no voice called {voice}")
        speed = min(2.0, max(0.5, float(speed)))
        passes = [(text, tokens(text, self.table)) for text in batches(phonemes)]
        passes = [(text, ids) for text, ids in passes if ids]
        parts = []
        for i, (text, ids) in enumerate(passes):
            feeds = {
                "tokens": np.array([[0, *ids, 0]], dtype=np.int64),
                "style": np.asarray(styles[min(len(ids), len(styles)) - 1], dtype=np.float32),
                "speed": np.array([speed], dtype=np.float32),
            }
            audio = trim(np.asarray(self.session.run(None, feeds)[0], dtype=np.float32).ravel())
            if i < len(passes) - 1:
                audio = np.concatenate([audio, np.zeros(int(pause_after(text) * RATE), np.float32)])
            parts.append(audio)
        return np.concatenate(parts) if parts else np.zeros(0, np.float32)
