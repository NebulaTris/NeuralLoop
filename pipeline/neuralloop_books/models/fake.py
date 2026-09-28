"""A deterministic stand-in model for dry runs and tests: canned, valid JSON for every kind of prompt."""

import asyncio
import json
import re

from .. import fake_client

_TITLE = re.compile(r'chapter "([^"]+)"')
_IDEA = re.compile(r'Idea: "(.*)"\n')
_ANSWER = re.compile(r"<<<(.*)>>>", re.DOTALL)


def _recall(prompt: str) -> dict:
    from ..recall import word_match

    idea, answer = _IDEA.search(prompt).group(1), _ANSWER.search(prompt).group(1)
    covered = word_match([idea], answer)[0]
    return {"covered": covered, "evidence": idea if covered else ""}


def _podcast(title: str) -> dict:
    return {
        "title": f"Five minutes on {title}",
        "lines": [
            {
                "speaker": "A",
                "text": f"Hi and welcome! Today we're chatting about {title}.",
                "delivery": "happy, steady pace",
            },
            {
                "speaker": "B",
                "text": "It's a good one. The core idea is a trade-off you meet everywhere.",
                "delivery": "warm",
            },
            {"speaker": "A", "text": "So when does it actually matter? <chuckle>", "delivery": "curious"},
            {
                "speaker": "B",
                "text": "When things break. Check the simple bugs first, then monitor.",
                "delivery": "steady pace",
            },
            {
                "speaker": "A",
                "text": "Lovely. Quick recap: know the trade-off, keep it simple, and watch it run.",
                "delivery": "excited",
            },
        ],
    }


def _explainer(title: str) -> dict:
    return {
        "slides": [
            {
                "title": f"Welcome to {title}",
                "points": ["What this chapter is about"],
                "narration": f"Hi! I'm Pip. Let's explore {title} together.",
                "pose": "hop",
            },
            {
                "title": "The core trade-off",
                "points": ["Every choice costs something", "Know when it matters"],
                "narration": "Every design choice costs something. The trick is knowing when it matters.",
                "pose": "study",
            },
            {
                "title": "When it breaks",
                "points": ["Check simple bugs first", "Monitor early"],
                "narration": "When it breaks, check simple bugs first. Monitor to hear about it early.",
                "pose": "play",
            },
            {
                "title": "Recap",
                "points": ["Trade-offs", "Simplicity", "Monitoring"],
                "narration": "You did it! Trade-offs, simplicity, and monitoring. See you next chapter.",
                "pose": "proud",
            },
        ]
    }


class FakeModel:
    name = "Pip's practice brain"
    provider = "fake"
    model = "fake"

    def __init__(self, delay: float = 0.0):
        self.delay = delay
        self.calls: list[tuple[str, str]] = []

    async def check(self) -> None:
        return None

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        self.calls.append((kind, prompt))
        await asyncio.sleep(self.delay)
        match = _TITLE.search(prompt)
        title = match.group(1) if match else "this chapter"
        answers = {
            "study": lambda: fake_client._study(title),
            "graph": lambda: fake_client._graph(title),
            "quiz": lambda: {"questions": fake_client._quiz(title)},
            "cards": lambda: {"cards": fake_client._cards(title)},
            "mindmap": lambda: fake_client._mind_map(title),
            "audio": lambda: _podcast(title),
            "video": lambda: _explainer(title),
            "condense": lambda: {"notes": f"- Key idea from this part ({len(source)} characters)."},
            "recall": lambda: _recall(prompt),
        }
        return json.dumps(answers[kind]())
