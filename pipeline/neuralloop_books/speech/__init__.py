"""Speech engines for podcasts and explainer narration. Each writes one WAV file per call (blocking)."""

import shutil
from typing import Protocol

from ..models import SetupError


class SpeechEngine(Protocol):
    name: str
    voices: tuple[str, str]  # host A, host B (A also narrates explainers)

    def check(self) -> None: ...

    def synth(self, text: str, voice: str, delivery: str, path) -> None: ...


def rumik_installed() -> bool:
    try:
        import mlx_audio  # noqa: F401
    except ImportError:
        return False
    return True


def make_speech(name: str, voices: str | None = None) -> SpeechEngine:
    """`auto` is Rumik when mlx-audio is installed, otherwise the macOS voices."""
    if name == "auto":
        name = "rumik" if rumik_installed() else "say"
    chosen = tuple(v.strip() for v in voices.split(",")) if voices else None
    if chosen is not None and len(chosen) != 2:
        raise SetupError("Give two voices, one per host, for example: --voices Ira,Zoya")
    if name == "rumik":
        from .rumik import RumikSpeech

        return RumikSpeech(chosen)
    if name == "say":
        from .say import SaySpeech

        return SaySpeech(chosen, executable=shutil.which("say"))
    if name == "fake":
        from .fake import FakeSpeech

        return FakeSpeech()
    raise SetupError(f"Unknown speech engine: {name}")
