"""JSON schemas for each item, used to constrain local models (Ollama turns a schema into a grammar, so the
model can only produce the right shape). Kept in step with the prompts in prompts.py and checks in convert.py.
"""

_STR = {"type": "string"}


def _obj(properties: dict, required: list[str] | None = None) -> dict:
    return {"type": "object", "properties": properties, "required": required or list(properties)}


def _list(items: dict, low: int, high: int) -> dict:
    return {"type": "array", "items": items, "minItems": low, "maxItems": high}


def _enum(*values: str) -> dict:
    return {"type": "string", "enum": list(values)}


def _mind_map_node(depth: int) -> dict:
    """A node with children down to `depth` more levels; the deepest level has none (no endless nesting)."""
    if depth == 0:
        return _obj({"name": _STR})
    return _obj({"name": _STR, "children": _list(_mind_map_node(depth - 1), 0 if depth == 1 else 1, 6)})


SCHEMAS = {
    "study": _obj(
        {
            "guide": _list(
                _obj({"section": _STR, "level": _enum("deep", "normal", "skim"), "why": _STR}), 2, 12
            ),
            "recall": _list(_obj({"prompt": _STR, "keyPoints": _list(_STR, 3, 5)}), 3, 3),
        }
    ),
    "graph": _obj(
        {
            "concepts": _list(
                _obj(
                    {
                        "id": _STR,
                        "name": _STR,
                        "type": _enum("concept", "claim", "topic"),
                        "summary": _STR,
                        "detail": _STR,
                        "complexity": _enum("simple", "moderate", "complex"),
                        "layer": _STR,
                    }
                ),
                8,
                14,
            ),
            "layers": _list(_obj({"id": _STR, "name": _STR}), 2, 4),
            "edges": _list(
                _obj(
                    {
                        "source": _STR,
                        "target": _STR,
                        "type": _enum(
                            "depends_on",
                            "builds_on",
                            "related",
                            "contradicts",
                            "exemplifies",
                            "categorized_under",
                        ),
                        "description": _STR,
                    }
                ),
                4,
                30,
            ),
            "tour": _list(_obj({"title": _STR, "description": _STR, "nodeIds": _list(_STR, 1, 5)}), 3, 5),
        }
    ),
    "quiz": _obj(
        {
            "questions": _list(
                _obj(
                    {
                        "question": _STR,
                        "hint": _STR,
                        "answerOptions": _list(
                            _obj({"text": _STR, "isCorrect": {"type": "boolean"}, "rationale": _STR}), 4, 4
                        ),
                    }
                ),
                8,
                10,
            )
        }
    ),
    "cards": _obj({"cards": _list(_obj({"front": _STR, "back": _STR}), 12, 20)}),
    "mindmap": _mind_map_node(3),
    "audio": _obj(
        {
            "title": _STR,
            "lines": _list(_obj({"speaker": _enum("A", "B"), "text": _STR, "delivery": _STR}), 8, 120),
        }
    ),
    "video": _obj(
        {
            "slides": _list(
                _obj(
                    {
                        "title": _STR,
                        "points": _list(_STR, 1, 4),
                        "narration": _STR,
                        "pose": _enum("read", "hop", "study", "play", "proud", "hug"),
                    }
                ),
                3,
                8,
            )
        }
    ),
    "condense": _obj({"notes": _STR}),
    "recall": _obj({"covered": {"type": "boolean"}, "evidence": _STR}),
}
