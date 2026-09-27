"""Turn model and NotebookLM outputs (chat answers and downloaded JSON) into NeuralLoop's formats.

Every converter is tolerant: it drops items that are incomplete instead of failing, and
returns ``None`` (or an empty list) when nothing usable remains.
"""

import json
import re
from typing import Any

_CITATION = re.compile(r"\s*\[\d+(?:\s*[,\-–]\s*\d+)*\]")
_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)
# Small models sometimes open or close a JSON string with a curly quote; only fixed when parsing fails.
_CURLY_CLOSE = re.compile(r"[”“](?=\s*[,}\]:])")
_CURLY_OPEN = re.compile(r"(?<=[\[{,:])(\s*)[“”]")
_GUIDE_LEVELS = ("deep", "normal", "skim")
_MAX_CONCEPTS = 16
_MIND_MAP_DEPTH = 4  # root plus three levels
_MAX_SLIDES = 8
_POSES = ("read", "hop", "nap", "stretch", "play", "hug", "study", "proud")


def loose_json(text: str | None) -> Any:
    """Parse JSON from a chat answer that may wrap it in prose, code fences, or citation markers."""
    cleaned = _CITATION.sub("", text or "").strip()
    parsed = _parse(cleaned)
    if parsed is None and ("”" in cleaned or "“" in cleaned):
        parsed = _parse(_CURLY_OPEN.sub(r'\1"', _CURLY_CLOSE.sub('"', cleaned)))
    return parsed


def _parse(cleaned: str) -> Any:
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


def mind_map(data: Any) -> dict | None:
    """Model answer -> {name, children:[{name, children}]}; empty names dropped, depth capped."""

    def node(item: Any, depth: int) -> dict | None:
        if not isinstance(item, dict) or not str(item.get("name", "")).strip():
            return None
        result: dict = {"name": str(item["name"]).strip()[:80]}
        if depth < _MIND_MAP_DEPTH - 1:
            children = [c for c in (node(child, depth + 1) for child in _list(item, "children")) if c]
            if children:
                result["children"] = children
        return result

    return node(data, 0)


def podcast_script(data: Any) -> dict | None:
    """Model answer -> {title, lines:[{speaker: "A"|"B", text, delivery}]}; needs both hosts."""
    lines = []
    for line in _list(data, "lines"):
        speaker, text = str(line.get("speaker", "")).strip().upper(), str(line.get("text", "")).strip()
        if speaker in ("A", "B") and text:
            lines.append(
                {"speaker": speaker, "text": text, "delivery": str(line.get("delivery", "")).strip()}
            )
    if {line["speaker"] for line in lines} != {"A", "B"}:
        return None
    return {"title": str(data.get("title", "")).strip(), "lines": lines}


def explainer(data: Any) -> dict | None:
    """Model answer -> {slides:[{title, points, narration, pose}]}; slides need a title and narration."""
    slides = []
    for slide in _list(data, "slides"):
        title, narration = str(slide.get("title", "")).strip(), str(slide.get("narration", "")).strip()
        if not title or not narration:
            continue
        points = [str(p).strip() for p in slide.get("points") or [] if str(p).strip()][:5]
        pose = slide.get("pose") if slide.get("pose") in _POSES else "read"
        slides.append({"title": title[:90], "points": points, "narration": narration, "pose": pose})
    return {"slides": slides[:_MAX_SLIDES]} if slides else None


def _list(data: Any, key: str) -> list[dict]:
    """The list of dicts at ``data[key]``, or [] when the shape is wrong."""
    value = data.get(key) if isinstance(data, dict) else None
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []
