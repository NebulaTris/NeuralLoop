"""Speech engines for podcasts and explainer narration. Each writes one WAV file per call (blocking).

Rumik OSS-1 is the voice of NeuralLoop; `fake` exists only for dry runs and tests.
"""

from typing import Protocol

from ..models import SetupError


class SpeechEngine(Protocol):
    name: str
    voices: tuple[str, str]  # host A, host B (A also narrates explainers)

    def check(self) -> None: ...

    def synth(self, text: str, voice: str, delivery: str, path) -> None: ...


def make_speech(name: str, voices: str | None = None) -> SpeechEngine:
    chosen = tuple(v.strip() for v in voices.split(",")) if voices else None
    if chosen is not None and len(chosen) != 2:
        raise SetupError("Give two voices, one per host, for example: --voices Ira,Zoya")
    if name in ("auto", "rumik"):
        from .rumik import RumikSpeech

        return RumikSpeech(chosen)
    if name == "fake":
        from .fake import FakeSpeech

        return FakeSpeech()
    raise SetupError(f"Unknown speech engine: {name}. NeuralLoop speaks with Rumik.")
