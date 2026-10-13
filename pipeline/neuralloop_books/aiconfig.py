"""Each person's AI choices (ai.json, written by the app's Settings): which engine, which model makes study
material (optionally a different one per item), which model checks recall, Rumik's two voices, and whether
Hermes Agent may run with its tools on (`hermesTools`, off unless the person turns it on).

Everything has a default, so a missing or broken file still works out of the box, and a part with the wrong
shape (tasks that aren't choices, voices that aren't two names) is ignored. Keys never live here.
"""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from .config import AUDIO_LENGTHS

DEFAULT_RECALL_MODEL = "gemma2:2b"  # small and quick: grading one answer should feel instant


@dataclass(frozen=True)
class ModelChoice:
    provider: str = "auto"
    model: str | None = None
    base_url: str | None = None


@dataclass(frozen=True)
class AIConfig:
    engine: str = "auto"
    make: ModelChoice = field(default_factory=ModelChoice)
    tasks: dict = field(default_factory=dict)  # task -> ModelChoice, e.g. {"quiz": ModelChoice("anthropic")}
    recall: ModelChoice = field(default_factory=lambda: ModelChoice("ollama", DEFAULT_RECALL_MODEL))
    voices: tuple[str, str] = ("Ira", "Zoya")
    audio_length: str = (
        "auto"  # podcast length: "auto" (short for short chapters), "short", "default", "long"
    )
    voice_quality: str = "fast"  # "fast" (Rumik 4-bit, ~2x quicker) or "best" (8-bit)
    # Hermes Agent's tools can't be turned off, and a book's text could steer them: only with this opt-in.
    hermes_tools: bool = False

    def task(self, name: str) -> ModelChoice:
        return self.tasks.get(name, self.make)


def default_path() -> Path | None:
    value = os.environ.get("NEURALLOOP_AI_CONFIG")
    return Path(value) if value else None


def _text(value) -> str | None:
    """A setting that should be words: a non-empty string, or None for anything else."""
    return value if isinstance(value, str) and value else None


def _choice(data, fallback: ModelChoice) -> ModelChoice:
    """A choice from ai.json; what it leaves out comes from `fallback`, but a model or address only when it's
    for the same provider (recall on Claude must never be asked for Ollama's gemma2:2b)."""
    if not isinstance(data, dict):
        return fallback
    provider = _text(data.get("provider")) or fallback.provider
    same = provider == fallback.provider
    return ModelChoice(
        provider=provider,
        model=_text(data.get("model")) or (fallback.model if same else None),
        base_url=_text(data.get("baseUrl")) or (fallback.base_url if same else None),
    )


def load(path: Path | None = None) -> AIConfig:
    path = path or default_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path and path.exists() else {}
    except (OSError, json.JSONDecodeError):
        data = {}  # a broken file must never stop a book; Settings can rewrite it
    if not isinstance(data, dict):
        data = {}
    defaults = AIConfig()
    make = _choice(data.get("make"), defaults.make)
    tasks = data.get("tasks") if isinstance(data.get("tasks"), dict) else {}
    tasks = {name: _choice(value, make) for name, value in tasks.items() if isinstance(value, dict)}
    voices = data.get("voices")
    two_voices = isinstance(voices, list) and len(voices) == 2 and all(_text(v) for v in voices)
    return AIConfig(
        engine=_text(data.get("engine")) or defaults.engine,
        make=make,
        tasks=tasks,
        recall=_choice(data.get("recall"), defaults.recall),
        voices=tuple(voices) if two_voices else defaults.voices,
        voice_quality="best" if data.get("voiceQuality") == "best" else "fast",
        audio_length=data.get("audioLength") if data.get("audioLength") in AUDIO_LENGTHS else "auto",
        hermes_tools=data.get("hermesTools") is True,
    )
