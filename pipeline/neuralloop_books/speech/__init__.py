"""Speech engines for podcasts and explainer narration. Each writes one WAV file per call (blocking).

Rumik OSS-1 is the voice of NeuralLoop on a Mac (Apple silicon only: an Intel Mac is told so, since the Mac's
runtime has no Kokoro); Kokoro is the voice on Windows and Linux; `fake` exists only for dry runs and tests.
"""

import platform
import re
from typing import Protocol

from ..models import SetupError


class SpeechEngine(Protocol):
    name: str
    voices: tuple[str, str]  # host A, host B (A also narrates explainers)

    def check(self) -> None: ...

    def synth(self, text: str, voice: str, delivery: str, path) -> None: ...


def apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() == "arm64"


_KOKORO_ID = re.compile(r"[a-z][fm]_([a-z]+)")


def host_name(voice: str) -> str:
    """What the podcast's script calls a host: Kokoro's `af_heart` is Heart; Rumik's names are names
    already."""
    found = _KOKORO_ID.fullmatch(voice)
    return found.group(1).capitalize() if found else voice


def make_speech(
    name: str, voices: str | None = None, quality: str = "fast", language: str = "en"
) -> SpeechEngine:
    chosen = tuple(v.strip() for v in voices.split(",")) if voices else None
    if chosen is not None and len(chosen) != 2:
        raise SetupError("Give two voices, one per host, for example: --voices Ira,Zoya")
    if name == "auto":
        name = "rumik" if platform.system() == "Darwin" else "kokoro"  # Rumik's check explains Intel Macs
    if name == "kokoro":
        from .kokoro import KokoroSpeech

        return KokoroSpeech(chosen, quality=quality, language=language)
    if name == "rumik":
        from .rumik import RumikSpeech

        return RumikSpeech(chosen, quality=quality)
    if name == "fake":
        from .fake import FakeSpeech

        return FakeSpeech()
    raise SetupError(f"Unknown speech engine: {name}. NeuralLoop speaks with Rumik or Kokoro.")
