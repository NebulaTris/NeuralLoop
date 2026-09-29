"""Each person's AI choices (ai.json, written by the app's Settings): which engine, which model makes study
material (optionally a different one per item), which model checks recall, and Rumik's two voices.

Everything has a default, so a missing or broken file still works out of the box. Keys never live here.
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

    def task(self, name: str) -> ModelChoice:
        return self.tasks.get(name, self.make)


def default_path() -> Path | None:
    value = os.environ.get("NEURALLOOP_AI_CONFIG")
    return Path(value) if value else None


def _choice(data, fallback: ModelChoice) -> ModelChoice:
    if not isinstance(data, dict):
        return fallback
    return ModelChoice(
        provider=str(data.get("provider") or fallback.provider),
        model=data.get("model") or fallback.model,
        base_url=data.get("baseUrl") or fallback.base_url,
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
    tasks = {name: _choice(value, make) for name, value in (data.get("tasks") or {}).items()}
    voices = data.get("voices")
    return AIConfig(
        engine=str(data.get("engine") or defaults.engine),
        make=make,
        tasks=tasks,
        recall=_choice(data.get("recall"), defaults.recall),
        voices=tuple(voices) if isinstance(voices, list) and len(voices) == 2 else defaults.voices,
        voice_quality="best" if data.get("voiceQuality") == "best" else "fast",
        audio_length=data.get("audioLength") if data.get("audioLength") in AUDIO_LENGTHS else "auto",
    )
