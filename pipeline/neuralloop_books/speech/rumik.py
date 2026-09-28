"""Rumik OSS-1 (https://huggingface.co/rumik-ai/rumik-oss-1-mlx-8bit) on Apple silicon through mlx-audio.

Expressive voices (Ira, Aisha, Siya, Zoya), a `delivery` description ("happy, steady pace"), and inline
<laugh>, <chuckle>, <sigh>. License: CC-BY-NC 4.0 with an acceptable-use addendum (non-commercial use).
"""

import os
import platform
import wave

from ..models import SetupError

RATE = 24_000
VOICES = ("Ira", "Aisha", "Siya", "Zoya")
MODEL_8BIT = "rumik-ai/rumik-oss-1-mlx-8bit"  # ~3.8 GB of memory while speaking
MODEL_4BIT = "rumik-ai/rumik-oss-1-mlx-4bit"  # for Macs with less than 16 GB
_GB = 1024**3


def total_memory() -> int:
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")


def model_for_memory(memory: int) -> str:
    return MODEL_8BIT if memory >= 16 * _GB else MODEL_4BIT


class RumikSpeech:
    name = "Rumik OSS-1"

    def __init__(self, voices: tuple[str, str] | None, model: str | None = None):
        self.voices = voices or ("Ira", "Zoya")
        self.model = model or os.environ.get("NEURALLOOP_RUMIK_MODEL") or model_for_memory(total_memory())
        self._model = None

    def check(self) -> None:
        unknown = [v for v in self.voices if v not in VOICES]
        if unknown:
            raise SetupError(
                f"Rumik's voices are {', '.join(VOICES)}; {', '.join(unknown)} isn't one of them."
            )
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise SetupError("Rumik voices need a Mac with Apple silicon (M1 or newer).")
        try:
            import mlx_audio  # noqa: F401
        except ImportError as error:
            raise SetupError(
                "Rumik voices aren't installed yet. Open NeuralLoop once to finish setup."
            ) from error

    def load(self):
        if self._model is None:
            from mlx_audio.tts.utils import load

            self._model = load(self.model)  # downloaded once by setup, then read from the cache
        return self._model

    def synth(self, text: str, voice: str, delivery: str, path) -> None:
        import numpy as np

        chunks = [
            np.asarray(chunk.audio, dtype=np.float32)
            for chunk in self.load().generate(
                text, voice=voice, instruct=delivery or "warm, steady pace", stream=True
            )
        ]
        audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2")
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(pcm.tobytes())
