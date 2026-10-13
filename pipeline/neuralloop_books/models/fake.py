"""A deterministic stand-in model for dry runs and tests: canned, valid JSON for every kind of prompt."""

import asyncio
import json
import re

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
            "study": lambda: study(title),
            "graph": lambda: graph(title),
            "quiz": lambda: {"questions": quiz(title)},
            "cards": lambda: {"cards": cards(title)},
            "mindmap": lambda: mind_map(title),
            "audio": lambda: _podcast(title),
            "video": lambda: _explainer(title),
            "condense": lambda: {"notes": f"- Key idea from this part ({len(source)} characters)."},
            "recall": lambda: _recall(prompt),
            "check": lambda: {"ok": True},
        }
        return json.dumps(answers[kind]())


# ---- canned answers (tests/fake_client.py, the offline NotebookLM, gives the same) ----


def study(title: str):
    return {
        "guide": [
            {"section": "Part one", "level": "deep", "why": "The core idea; everything later builds on it."}
        ],
        "recall": [
            {
                "prompt": f'In your own words, what is the main idea of "{title}"?',
                "keyPoints": ["Names the core trade-off", "Says when it matters", "Gives a concrete example"],
            },
            {
                "prompt": "Something breaks in production. What would you check first, and why?",
                "keyPoints": [
                    "Rule out simple bugs first",
                    "Look at monitoring signals",
                    "Change one thing at a time",
                ],
            },
            {
                "prompt": "How would you explain this chapter to a new teammate in two minutes?",
                "keyPoints": [
                    "Starts with the problem",
                    "Explains the key idea",
                    "Ends with one practical tip",
                ],
            },
        ],
    }


def graph(title: str):
    names = [
        "Basics",
        "Core trade-off",
        "Failure modes",
        "Monitoring",
        "Design patterns",
        "Keep it simple",
        "Testing",
    ]
    concepts = [
        {
            "id": f"k{i}",
            "name": name,
            "type": "claim" if i == 5 else "concept",
            "summary": f"What '{name}' means in {title}.",
            "detail": f"A longer note about {name}.",
            "complexity": ("simple", "moderate", "complex")[i % 3],
            "layer": "l1" if i < 4 else "l2",
        }
        for i, name in enumerate(names)
    ]
    edges = [
        ("k1", "k0", "builds_on"),
        ("k2", "k1", "depends_on"),
        ("k3", "k2", "related"),
        ("k4", "k1", "builds_on"),
        ("k5", "k4", "contradicts"),
        ("k6", "k3", "exemplifies"),
    ]
    return {
        "concepts": concepts,
        "layers": [{"id": "l1", "name": "Foundations"}, {"id": "l2", "name": "In practice"}],
        "edges": [
            {"source": s, "target": t, "type": kind, "description": kind.replace("_", " ")}
            for s, t, kind in edges
        ],
        "tour": [
            {"title": "Start here", "description": "The basic idea.", "nodeIds": ["k0"]},
            {"title": "Where it breaks", "description": "Trade-offs and failures.", "nodeIds": ["k1", "k2"]},
        ],
    }


def quiz(title: str):
    def question(text, right, wrong):
        options = [{"text": right, "isCorrect": True, "rationale": "That's the chapter's central point."}]
        options += [
            {"text": w, "isCorrect": False, "rationale": "Not what the chapter argues."} for w in wrong
        ]
        return {"question": text, "answerOptions": options, "hint": "Think about the trade-off."}

    return [
        question(
            f'What is the main idea of "{title}"?',
            "A core trade-off and when it matters",
            ["A list of unrelated facts", "Only history", "Nothing matters"],
        ),
        question(
            "What should you check first when something breaks?",
            "Simple engineering bugs",
            ["Rewrite everything", "Ignore it", "Blame the users"],
        ),
    ]


def cards(title: str):
    return [
        {"front": f"Main idea of {title}", "back": "A core trade-off and when it matters."},
        {"front": "First thing to check when it breaks", "back": "Simple engineering bugs."},
        {"front": "Why monitor?", "back": "Problems show up before users complain."},
    ]


def mind_map(title: str):
    return {
        "name": title,
        "children": [
            {"name": "Foundations", "children": [{"name": "Key terms"}, {"name": "Core trade-off"}]},
            {"name": "In practice", "children": [{"name": "Patterns"}, {"name": "Failure modes"}]},
            {"name": "Takeaways"},
        ],
    }
