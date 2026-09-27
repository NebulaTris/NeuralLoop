"""Rumik OSS-1 (https://huggingface.co/rumik-ai/rumik-oss-1-mlx-8bit) on Apple silicon through mlx-audio.

Expressive voices (Ira, Aisha, Siya, Zoya), a `delivery` description ("happy, steady pace"), and inline
<laugh>, <chuckle>, <sigh>. License: CC-BY-NC 4.0 with an acceptable-use addendum (non-commercial use).
"""

import wave

from ..models import SetupError

MODEL = "rumik-ai/rumik-oss-1-mlx-8bit"
RATE = 24_000
VOICES = ("Ira", "Aisha", "Siya", "Zoya")


class RumikSpeech:
    name = "Rumik OSS-1"

    def __init__(self, voices: tuple[str, str] | None):
        self.voices = voices or ("Ira", "Zoya")
        self._model = None

    def check(self) -> None:
        unknown = [v for v in self.voices if v not in VOICES]
        if unknown:
            raise SetupError(
                f"Rumik's voices are {', '.join(VOICES)}; {', '.join(unknown)} isn't one of them."
            )
        try:
            import mlx_audio  # noqa: F401
        except ImportError as error:
            raise SetupError(
                'Rumik needs mlx-audio. Run: pip install "neuralloop-books-pipeline[rumik]"'
            ) from error

    def _load(self):
        if self._model is None:
            from mlx_audio.tts.utils import load

            self._model = load(MODEL)  # downloads ~3.6 GB the first time
        return self._model

    def synth(self, text: str, voice: str, delivery: str, path) -> None:
        import numpy as np

        chunks = [
            np.asarray(chunk.audio, dtype=np.float32)
            for chunk in self._load().generate(
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
