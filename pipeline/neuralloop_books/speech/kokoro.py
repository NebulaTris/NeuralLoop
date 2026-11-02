"""Kokoro-82M (https://huggingface.co/hexgrad/Kokoro-82M): the local voice on Windows and Linux, where Rumik
(Apple silicon only) can't run. Runs on the CPU with ONNX Runtime (`kokoro_model.py`); its phonemes come from
espeak-ng, run as a separate program (`espeak.py`).

Model: Apache-2.0. espeak-ng: GPL-3.0, never loaded into this process (see NOTICE.md).
The model files come from kokoro-onnx's GitHub release and are checked by SHA-256 before they're used.
"""

import hashlib
import os
import re
import tempfile
import urllib.request
import wave
from collections.abc import Callable
from pathlib import Path

from .. import portable
from ..models import SetupError
from . import espeak
from .kokoro_model import KokoroModel

RATE = 24_000
RELEASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"
# name: (SHA-256, size in bytes)
FILES = {
    "kokoro-v1.0.int8.onnx": ("6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb", 92_361_271),
    "kokoro-v1.0.onnx": ("7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5", 325_532_387),
    "voices-v1.0.bin": ("bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d", 28_214_398),
}
VOICES_FILE = "voices-v1.0.bin"

# The English voices Settings offers: (id, what people see). American/British (a/b), female/male (f/m).
VOICES = (
    ("af_heart", "Heart (warm, American)"),
    ("af_bella", "Bella (bright, American)"),
    ("af_nicole", "Nicole (soft, American)"),
    ("af_sarah", "Sarah (clear, American)"),
    ("am_michael", "Michael (friendly, American)"),
    ("am_adam", "Adam (deep, American)"),
    ("am_puck", "Puck (lively, American)"),
    ("bf_emma", "Emma (British)"),
    ("bf_isabella", "Isabella (British)"),
    ("bm_george", "George (British)"),
    ("bm_fable", "Fable (British)"),
)
VOICE_IDS = tuple(v for v, _ in VOICES)
DEFAULT_VOICES = ("af_heart", "am_michael")
# A book in another language: Kokoro's voices for it (host A, host B; French has one), whose first letter is
# the language. Kokoro's Japanese and Chinese need a phonemizer other than espeak-ng; it has no German voice.
LANGUAGE_VOICES = {
    "es": ("ef_dora", "em_alex"),
    "fr": ("ff_siwis", "ff_siwis"),
    "hi": ("hf_alpha", "hm_omega"),
}
ESPEAK_LANGUAGES = {"a": "en-us", "b": "en-gb", "e": "es", "f": "fr-fr", "h": "hi"}
LANGUAGE_NAMES = {"de": "German", "ja": "Japanese", "zh": "Chinese", "ko": "Korean"}
# ai.json made on a Mac (and the shared defaults) names Rumik's voices: keep each host's place.
RUMIK_NAMES = {"Ira": "af_heart", "Aisha": "af_bella", "Siya": "af_nicole", "Zoya": "am_michael"}

# Rumik's own delivery tags, and only those: `List<String>` and `<T>` in a book are part of what it says.
_TAGS = re.compile(r"\s*<\s*/?\s*(?:laugh|chuckle|sigh)\s*/?\s*>\s*", re.IGNORECASE)


def folder() -> Path:
    return Path(os.environ.get("NEURALLOOP_KOKORO_DIR") or portable.app_data() / "voices" / "kokoro")


def model_file(quality: str, where: Path | None = None) -> Path:
    """ "fast" (default): the 8-bit model, about three times smaller and quicker; "best": full precision."""
    name = "kokoro-v1.0.onnx" if quality == "best" else "kokoro-v1.0.int8.onnx"
    return (where or folder()) / name


def needed(quality: str) -> list[str]:
    return [model_file(quality, Path()).name, VOICES_FILE]


def ready(where: Path, quality: str) -> bool:
    return all(
        (where / name).is_file() and (where / name).stat().st_size == FILES[name][1]
        for name in needed(quality)
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(where: Path, names: list[str], progress: Callable[[float], None]) -> None:
    """Fetch what's missing (or damaged) into `where`, checking each file's SHA-256 before keeping it."""
    where.mkdir(parents=True, exist_ok=True)
    todo = []
    for name in names:
        path = where / name
        if path.is_file() and path.stat().st_size == FILES[name][1] and _sha256(path) == FILES[name][0]:
            continue
        todo.append(name)
    total = sum(FILES[name][1] for name in todo) or 1
    got = 0
    for name in todo:
        expected = FILES[name][0]
        # Its own temporary file: two books' runs may download at once, and neither may see the other's half.
        handle, partial_name = tempfile.mkstemp(prefix=f"{name}.", suffix=".part", dir=where)
        os.close(handle)
        partial = Path(partial_name)
        digest = hashlib.sha256()
        try:
            with urllib.request.urlopen(RELEASE + name, timeout=60) as response, open(partial, "wb") as out:
                for block in iter(lambda: response.read(1 << 20), b""):
                    out.write(block)
                    digest.update(block)
                    got += len(block)
                    progress(min(got / total, 0.999))
        except OSError as error:
            partial.unlink(missing_ok=True)
            raise SetupError(
                f"Couldn't download Kokoro's voices ({error}). Check the connection and try again."
            ) from None
        if digest.hexdigest() != expected:
            partial.unlink(missing_ok=True)
            raise SetupError(f"The downloaded {name} didn't match the expected file. Try again later.")
        target = where / name
        if target.is_file() and target.stat().st_size == FILES[name][1] and _sha256(target) == expected:
            partial.unlink(missing_ok=True)  # another run finished first (and may already be using it)
        else:
            portable.replace(partial, target)
    progress(1.0)


def speed_for(delivery: str) -> float:
    """Kokoro has no delivery instructions like Rumik's; a pace word nudges the speed a little."""
    words = delivery.lower()
    if any(w in words for w in ("quick", "fast", "excited", "brisk", "energetic")):
        return 1.08
    if any(w in words for w in ("slow", "calm", "thoughtful", "gentle")):
        return 0.94
    return 1.0


def _voice(name: str) -> str:
    return RUMIK_NAMES.get(name, name)


def language(voice: str) -> str:
    """espeak-ng's language for a voice, from its first letter: Kokoro's British voices (bf_, bm_) were made
    with British pronunciations, its American ones (af_, am_) with American, its Spanish ones in Spanish…"""
    return ESPEAK_LANGUAGES.get(voice[:1], "en-us")


def _voices_for(chosen: tuple[str, ...] | None, book_language: str) -> tuple[str, str]:
    voices = tuple(_voice(v) for v in chosen) if chosen else DEFAULT_VOICES
    wanted = LANGUAGE_VOICES.get(book_language)
    if wanted and any(v[:1] != wanted[0][:1] for v in voices):  # English voices can't read Spanish well
        return wanted
    return voices


class KokoroSpeech:
    name = "Kokoro"

    def __init__(self, voices: tuple[str, str] | None, quality: str = "fast", language: str = "en"):
        self.book_language = (language or "en").split("-")[0].lower()
        self.voices = _voices_for(voices, self.book_language)
        self.quality = "best" if quality == "best" else "fast"
        self._model = None

    def check(self) -> None:
        if self.book_language != "en" and self.book_language not in LANGUAGE_VOICES:
            spoken = LANGUAGE_NAMES.get(self.book_language, self.book_language)
            raise SetupError(
                f"Kokoro can't speak {spoken}, so this PC can't voice podcasts and videos in it. NotebookLM "
                "can still make them: choose NotebookLM for them in Settings → Your AI."
            )
        known = {*VOICE_IDS, *(v for pair in LANGUAGE_VOICES.values() for v in pair)}
        unknown = [v for v in self.voices if v not in known]
        if unknown:
            raise SetupError(
                f"Kokoro's voices include {', '.join(VOICE_IDS[:4])}…; {', '.join(unknown)} isn't one."
            )
        try:
            import onnxruntime  # noqa: F401
        except ImportError as error:
            raise SetupError(
                "Kokoro voices aren't installed yet. Open NeuralLoop once to finish setup."
            ) from error
        espeak.require()

    def load(self, progress: Callable[[float], None] | None = None):
        if self._model is None:
            where = folder()
            if not ready(where, self.quality):
                download(where, needed(self.quality), progress or (lambda _: None))
            self._model = KokoroModel(model_file(self.quality, where), where / VOICES_FILE)
        return self._model

    def synth(self, text: str, voice: str, delivery: str, path) -> None:
        import numpy as np

        spoken = " ".join(_TAGS.sub(" ", text).split())
        voice = _voice(voice)
        audio = np.zeros(0, dtype=np.float32)
        if spoken:
            phonemes = espeak.phonemize(spoken, language(voice))
            if phonemes:
                audio = self.load().create(phonemes, voice, speed_for(delivery or ""))
        pcm = (np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2")
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(pcm.tobytes())
