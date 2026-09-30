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
        options = _list(item, "answerOptions")
        texts = [_text(o.get("text")) for o in options]
        correct = next((i for i, o in enumerate(options) if o.get("isCorrect") in (True, "true")), None)
        if _text(item.get("question")) and len(texts) >= 2 and correct is not None:
            questions.append(
                {
                    "q": _text(item["question"]),
                    "options": texts,
                    "a": correct,
                    "hint": _text(item.get("hint")),
                    "why": [_text(o.get("rationale")) for o in options],
                }
            )
    return questions


def flashcards(data: Any) -> list[dict]:
    """NotebookLM flashcard export -> [{front, back}]."""
    return [
        {"front": _text(c["front"]), "back": _text(c["back"])}
        for c in _list(data, "cards")
        if _text(c.get("front")) and _text(c.get("back"))
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
        {"prompt": str(r["prompt"]), "keyPoints": _texts(r.get("keyPoints"))[:6]}
        for r in _list(data, "recall")
        if r.get("prompt") and _texts(r.get("keyPoints"))
    ][:4]
    return {"guide": guide, "recall": recall} if guide or recall else None


def concept_graph(data: Any) -> dict | None:
    """Chat answer for the graph prompt -> {concepts, layers, edges, tour}.

    Every field becomes the plain string the app and the book map expect (a model can answer with anything,
    and one odd value must not break book.json); edges and tour steps pointing at unknown concepts go.
    """
    if not isinstance(data, dict):
        return None
    concepts = _first_of_each_id(
        {
            "id": _text(c["id"]),
            "name": _text(c["name"]),
            "type": _text(c.get("type")) or "concept",
            "summary": _text(c.get("summary")),
            "detail": _text(c.get("detail")),
            "complexity": _text(c.get("complexity")) or "moderate",
            "layer": _text(c.get("layer")),
        }
        for c in _list(data, "concepts")
        if _text(c.get("id")) and _text(c.get("name"))
    )[:_MAX_CONCEPTS]
    if not concepts:
        return None
    layers = [
        {"id": _text(layer["id"]), "name": _text(layer.get("name")) or _text(layer["id"])}
        for layer in _list(data, "layers")
        if _text(layer.get("id"))
    ] or [{"id": "core", "name": "Core ideas"}]
    layer_ids = {layer["id"] for layer in layers}
    for concept in concepts:
        if concept["layer"] not in layer_ids:
            concept["layer"] = layers[0]["id"]
    ids = {c["id"] for c in concepts}
    edges = [
        {
            "source": _text(e["source"]),
            "target": _text(e["target"]),
            "type": _text(e.get("type")) or "related",
            "description": _text(e.get("description")),
        }
        for e in _list(data, "edges")
        if _text(e.get("source")) in ids
        and _text(e.get("target")) in ids
        and _text(e["source"]) != _text(e["target"])
    ]
    tour = []
    for step in _list(data, "tour"):
        steps = step.get("nodeIds")
        node_ids = [_text(i) for i in steps if _text(i) in ids] if isinstance(steps, list) else []
        if node_ids:
            tour.append(
                {
                    "title": _text(step.get("title")),
                    "description": _text(step.get("description")),
                    "nodeIds": node_ids,
                }
            )
    return {"concepts": concepts, "layers": layers, "edges": edges, "tour": tour}


def _first_of_each_id(concepts) -> list[dict]:
    """Concepts with a repeated id are dropped (the first one stays), so every id names one idea."""
    seen: set[str] = set()
    kept = []
    for concept in concepts:
        if concept["id"] not in seen:
            seen.add(concept["id"])
            kept.append(concept)
    return kept


def _texts(value: Any) -> list[str]:
    """A list of strings from a model's list field. One string is one item (never split into letters);
    anything that isn't a list or a string gives nothing."""
    items = [value] if isinstance(value, str) else value if isinstance(value, list) else []
    return [text for text in (_text(item) for item in items) if text]


def _text(value: Any) -> str:
    """A model's string value; numbers become text, anything else (lists, objects, null) is empty."""
    return str(value).strip() if isinstance(value, (str, int, float)) and not isinstance(value, bool) else ""


def mind_map(data: Any) -> dict | None:
    """Model answer -> {name, children:[{name, children}]}; empty and repeated names dropped, depth capped."""

    def node(item: Any, depth: int) -> dict | None:
        if not isinstance(item, dict) or not str(item.get("name", "")).strip():
            return None
        result: dict = {"name": str(item["name"]).strip()[:80]}
        if depth < _MIND_MAP_DEPTH - 1:
            seen = {result["name"].lower()}  # a branch that repeats a sibling or its parent adds nothing
            children = []
            for child in (node(c, depth + 1) for c in _list(item, "children")):
                if child and child["name"].lower() not in seen:
                    seen.add(child["name"].lower())
                    children.append(child)
            if children:
                result["children"] = children
        return result

    return node(data, 0)


def graph_from_mind_map(tree: dict) -> dict | None:
    """A concept graph grown from a mind map, so a chapter's map exists even when a model can't draw one.

    Branches become the "Main ideas" layer, their children "Details"; each child points to its branch.
    """
    branches = [b for b in (tree or {}).get("children") or [] if b.get("name")][:6]
    if not branches:
        return None
    concepts, edges, used = [], [], set()

    def add(name: str, layer: str, parent: str | None, depth: int) -> None:
        cid = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or f"idea-{len(concepts)}"
        if cid in used or len(concepts) >= _MAX_CONCEPTS:
            return
        used.add(cid)
        complexity = ("complex", "moderate", "simple")[min(depth, 2)]
        concepts.append(
            {
                "id": cid,
                "name": name[:60],
                "type": "topic" if depth == 0 else "concept",
                "summary": "",
                "detail": "",
                "complexity": complexity,
                "layer": layer,
            }
        )
        if parent:
            edges.append(
                {"source": cid, "target": parent, "type": "categorized_under", "description": "part of"}
            )

    for branch in branches:
        add(branch["name"], "main", None, 0)
    for branch in branches:
        parent = re.sub(r"[^a-z0-9]+", "-", branch["name"].lower()).strip("-")[:40]
        for child in (branch.get("children") or [])[:4]:
            if child.get("name"):
                add(child["name"], "details", parent, 1)
    tour = [
        {
            "title": b["name"][:40],
            "description": f"What the chapter says about {b['name'].lower()}.",
            "nodeIds": [re.sub(r"[^a-z0-9]+", "-", b["name"].lower()).strip("-")[:40]],
        }
        for b in branches[:5]
    ]
    layers = [{"id": "main", "name": "Main ideas"}, {"id": "details", "name": "Details"}]
    return concept_graph({"concepts": concepts, "layers": layers, "edges": edges, "tour": tour})


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
        points = _texts(slide.get("points"))[:5]
        pose = slide.get("pose") if slide.get("pose") in _POSES else "read"
        slides.append({"title": title[:90], "points": points, "narration": narration, "pose": pose})
    return {"slides": slides[:_MAX_SLIDES]} if slides else None


def recall_verdict(data: Any) -> tuple[bool, str] | None:
    """Grader answer for one key point -> (covered, evidence), or None when it isn't a verdict."""
    if not isinstance(data, dict) or not isinstance(data.get("covered"), bool):
        return None
    return data["covered"], str(data.get("evidence", "")).strip()


def _list(data: Any, key: str) -> list[dict]:
    """The list of dicts at ``data[key]``, or [] when the shape is wrong."""
    value = data.get(key) if isinstance(data, dict) else None
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []
