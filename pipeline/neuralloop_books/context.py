"""Fitting a chapter into a model's context: send it as is, or condense long chapters into notes first."""

import json
from pathlib import Path

from . import convert, prompts


def chunks(text: str, budget: int) -> list[str]:
    """Split on paragraph boundaries into pieces of at most `budget` characters; nothing is lost."""
    if len(text) <= budget:
        return [text]
    pieces: list[str] = []
    current = ""
    for paragraph in text.split("\n\n"):
        for part in [paragraph[i : i + budget] for i in range(0, len(paragraph), budget)] or [""]:
            candidate = f"{current}\n\n{part}" if current else part
            if len(candidate) <= budget and (current or part):
                current = candidate
            else:
                pieces.append(current)
                current = part
    if current:
        pieces.append(current)
    return pieces


async def source_for(model, text: str, budget: int, cache: Path, system: str = "") -> str:
    """The chapter text if it fits, otherwise condensed notes (made once, then read from `cache`)."""
    if len(text) <= budget:
        return text
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))["notes"]
    pieces = chunks(text, budget)
    # Each part's notes get a share of the budget, so all the notes fit together (~6 characters a word).
    words = max(80, budget // len(pieces) // 6)
    notes = []
    for i, piece in enumerate(pieces, 1):
        ask = prompts.CONDENSE.format(part=i, parts=len(pieces), words=words)
        answer = await model.complete(
            "condense", system or prompts.SYSTEM.format(language="English"), piece, ask
        )
        data = convert.loose_json(answer)
        note = str(data["notes"]) if isinstance(data, dict) and data.get("notes") else answer
        notes.append(f"Notes on part {i} of {len(pieces)}:\n{note.strip()}")
    joined = "\n\n".join(notes)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"notes": joined}, ensure_ascii=False), encoding="utf-8")
    return joined
