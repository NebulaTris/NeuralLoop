"""Turn model and NotebookLM outputs (chat answers and downloaded JSON) into NeuralLoop's formats.

Every converter is tolerant: it drops items that are incomplete instead of failing, and
returns ``None`` (or an empty list) when nothing usable remains.
"""

import json
import re
import unicodedata
from typing import Any

# A NotebookLM citation ("… speed [1].", "Fast. [2, 3] Next", "end.[4]") follows prose and ends a clause.
# Never one right after a name or bracket (matrix[i][0], sorted([3, 1, 2])), after JSON punctuation
# ("ids": [1, 2]), or one going on into lower-case words ("x [1] times"), and never [0].
_CITE = r"\[(?!0\b)\d+(?:\s*[,\-–]\s*\d+)*\]"
_CITATION = re.compile(
    r"(?:(?<=[\w.!?;\"'”’*)])\s+|(?<=[.!?\"'”’]))"
    + rf"{_CITE}(?:\s*{_CITE})*"
    + r"(?=\s*(?:$|[.,;:!?)\"”’}\]])|\s+[^\sa-z])"
)
# Code a citation never sits in: a fence named for a language other than JSON, and `inline code`.
_CODE_SPAN = re.compile(r"(```(?!json\b)[A-Za-z][\w+#-]*[^\S\n]*\n.*?```|`[^`\n]*`)", re.DOTALL)
_PLUS = re.compile(r"(?<=[^\W_]|\+)\+")  # "c++", "g++": not "a + b"
_SHARP = re.compile(r"(?<=[^\W\d_])#")  # "c#", "f#": not "#1"
_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)
# Small models sometimes open or close a JSON string with a curly quote; only fixed when parsing fails.
_CURLY_CLOSE = re.compile(r"[”“](?=\s*[,}\]:])")
_CURLY_OPEN = re.compile(r"(?<=[\[{,:])(\s*)[“”]")
_GUIDE_LEVELS = ("deep", "normal", "skim")
_MAX_CONCEPTS = 16
_MIND_MAP_DEPTH = 4  # root plus three levels
_MAX_SLIDES = 8
_POSES = ("read", "hop", "nap", "stretch", "play", "hug", "study", "proud")


def loose_json(text: str | None, citations: bool = True) -> Any:
    """Parse JSON from a chat answer that may wrap it in prose, code fences, or citation markers.

    The answer is parsed as it is first, so number lists and code ("matrix[i][0]") survive; citation markers
    after prose are then taken out of its strings. Only an answer that doesn't parse is cleaned of them before
    parsing again. ``citations=False`` (a model that never cites) leaves every string as written.
    """
    raw = (text or "").strip()
    parsed = _parse(raw)
    if parsed is None and citations:
        raw = strip_citations(raw)
        parsed = _parse(raw)
    if parsed is None and ("”" in raw or "“" in raw):
        parsed = _parse(_CURLY_OPEN.sub(r'\1"', _CURLY_CLOSE.sub('"', raw)))
    return _without_citations(parsed) if citations else parsed


def strip_citations(text: str) -> str:
    """Text without NotebookLM's citation markers ("Caches help [1]." -> "Caches help."); code spans and
    brackets that belong to code or data stay as they are."""
    parts = _CODE_SPAN.split(text)
    return "".join(part if i % 2 else _CITATION.sub("", part) for i, part in enumerate(parts))


def _without_citations(value: Any) -> Any:
    if isinstance(value, str):
        cleaned = strip_citations(value)
        return cleaned.strip() if cleaned != value else value
    if isinstance(value, list):
        return [_without_citations(item) for item in value]
    if isinstance(value, dict):
        return {key: _without_citations(item) for key, item in value.items()}
    return value


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
    cards = [
        {"front": _card_side(c.get("front")), "back": _card_side(c.get("back"))} for c in _list(data, "cards")
    ]
    return [c for c in cards if c["front"] and c["back"]]


def _card_side(value: Any) -> str:
    """A card side: plain text, or NotebookLM's newer {"flashcardContentBlock": [{"type": "text", …}]}."""
    if isinstance(value, dict):
        blocks = value.get("flashcardContentBlock")
        if not isinstance(blocks, list):
            return ""
        texts = (_text(b.get("content")) for b in blocks if isinstance(b, dict) and b.get("type") == "text")
        return " ".join(t for t in texts if t)
    return _text(value)


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


def plain_words(text: str) -> str:
    """Letters, digits, and marks of any script (Devanagari vowel signs too), casefolded; anything else
    becomes a single space. "Кэш—Стратегия" -> "кэш стратегия", "Straße" -> "strasse". A plus or sharp sign
    that is part of a name stays a word, so "C++" ("c plus plus"), "C#" ("c sharp"), and "C" stay apart."""
    folded = unicodedata.normalize("NFKC", str(text)).casefold()
    folded = _SHARP.sub(" sharp ", _PLUS.sub(" plus ", folded))
    return " ".join("".join(c if unicodedata.category(c)[0] in "LNM" else " " for c in folded).split())


def slug(name: str) -> str:
    """An id from a name in any script: its words joined by dashes, at most 40 characters."""
    return "-".join(plain_words(name).split())[:40].strip("-")


def graph_from_mind_map(tree: dict) -> dict | None:
    """A concept graph grown from a mind map, so a chapter's map exists even when a model can't draw one.

    Branches become the "Main ideas" layer, their children "Details"; each child points to its branch.
    """
    branches = [b for b in (tree or {}).get("children") or [] if b.get("name")][:6]
    if not branches:
        return None
    concepts, edges, used = [], [], set()

    def add(name: str, layer: str, parent: str | None, depth: int) -> str | None:
        """The concept's id, or None when it's a repeat or there's no room."""
        cid = slug(name) or f"idea-{len(concepts)}"
        if cid in used or len(concepts) >= _MAX_CONCEPTS:
            return None
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
        return cid

    # Each branch's own id (the one `add` gave it), so links and the tour point at a concept that exists.
    placed = [(branch, add(branch["name"], "main", None, 0)) for branch in branches]
    placed = [(branch, cid) for branch, cid in placed if cid]
    for branch, cid in placed:
        for child in (branch.get("children") or [])[:4]:
            if child.get("name"):
                add(child["name"], "details", cid, 1)
    tour = [
        {
            "title": b["name"][:40],
            "description": f"What the chapter says about {b['name'].lower()}.",
            "nodeIds": [cid],
        }
        for b, cid in placed[:5]
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
