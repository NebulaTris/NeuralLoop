"""Turn NotebookLM outputs (chat answers and downloaded JSON) into NeuralLoop's formats.

Every converter is tolerant: it drops items that are incomplete instead of failing, and
returns ``None`` (or an empty list) when nothing usable remains.
"""

import json
import re
from typing import Any

_CITATION = re.compile(r"\s*\[\d+(?:\s*[,\-–]\s*\d+)*\]")
_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)
_GUIDE_LEVELS = ("deep", "normal", "skim")
_MAX_CONCEPTS = 16


def loose_json(text: str | None) -> Any:
    """Parse JSON from a chat answer that may wrap it in prose, code fences, or citation markers."""
    cleaned = _CITATION.sub("", text or "").strip()
    for candidate in (cleaned, *_FENCE.findall(cleaned)):
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if 0 <= start < end:
        try:
            return json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError:
            pass
    return None


def quiz(data: Any) -> list[dict]:
    """NotebookLM quiz export -> [{q, options, a, hint, why}]."""
    questions = []
    for item in _list(data, "questions"):
        options = item.get("answerOptions") or []
        texts = [str(o.get("text", "")) for o in options]
        correct = next((i for i, o in enumerate(options) if o.get("isCorrect")), None)
        if item.get("question") and len(texts) >= 2 and correct is not None:
            questions.append(
                {
                    "q": item["question"],
                    "options": texts,
                    "a": correct,
                    "hint": item.get("hint", ""),
                    "why": [str(o.get("rationale", "")) for o in options],
                }
            )
    return questions


def flashcards(data: Any) -> list[dict]:
    """NotebookLM flashcard export -> [{front, back}]."""
    return [
        {"front": c["front"], "back": c["back"]}
        for c in _list(data, "cards")
        if c.get("front") and c.get("back")
    ]


def study(data: Any) -> dict | None:
    """Chat answer for the study prompt -> {guide, recall}."""
    if not isinstance(data, dict):
        return None
    guide = [
        {
            "section": str(g["section"])[:120],
            "level": g.get("level") if g.get("level") in _GUIDE_LEVELS else "normal",
            "why": str(g.get("why", ""))[:200],
        }
        for g in _list(data, "guide")
        if g.get("section")
    ]
    recall = [
        {"prompt": str(r["prompt"]), "keyPoints": [str(k) for k in r["keyPoints"]][:6]}
        for r in _list(data, "recall")
        if r.get("prompt") and r.get("keyPoints")
    ][:4]
    return {"guide": guide, "recall": recall} if guide or recall else None


def concept_graph(data: Any) -> dict | None:
    """Chat answer for the graph prompt -> {concepts, layers, edges, tour}.

    Edges and tour steps that point at unknown concepts are removed.
    """
    if not isinstance(data, dict):
        return None
    concepts = [c for c in _list(data, "concepts") if c.get("id") and c.get("name")][:_MAX_CONCEPTS]
    if not concepts:
        return None
    layers = [layer for layer in _list(data, "layers") if layer.get("id")] or [
        {"id": "core", "name": "Core ideas"}
    ]
    layer_ids = {layer["id"] for layer in layers}
    for concept in concepts:
        concept.setdefault("type", "concept")
        concept.setdefault("complexity", "moderate")
        concept.setdefault("summary", "")
        concept.setdefault("detail", "")
        if concept.get("layer") not in layer_ids:
            concept["layer"] = layers[0]["id"]
    ids = {c["id"] for c in concepts}
    edges = [
        e
        for e in _list(data, "edges")
        if e.get("source") in ids and e.get("target") in ids and e["source"] != e["target"]
    ]
    tour = []
    for step in _list(data, "tour"):
        node_ids = [i for i in step.get("nodeIds", []) if i in ids]
        if node_ids:
            tour.append({**step, "nodeIds": node_ids})
    return {"concepts": concepts, "layers": layers, "edges": edges, "tour": tour}


def _list(data: Any, key: str) -> list[dict]:
    """The list of dicts at ``data[key]``, or [] when the shape is wrong."""
    value = data.get(key) if isinstance(data, dict) else None
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []
