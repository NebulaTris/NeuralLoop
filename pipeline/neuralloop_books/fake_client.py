"""An offline stand-in for notebooklm-py with the same method names, used for --dry-run and tests."""

import asyncio
import json
import math
import struct
import wave
from enum import Enum
from pathlib import Path
from types import SimpleNamespace

from .config import AUDIO_FORMATS, VIDEO_FORMATS, VIDEO_STYLES

ENUMS = SimpleNamespace(
    AudioFormat=Enum("AudioFormat", list(AUDIO_FORMATS.values())),
    AudioLength=Enum("AudioLength", ["SHORT", "DEFAULT", "LONG"]),
    VideoFormat=Enum("VideoFormat", list(VIDEO_FORMATS.values())),
    VideoStyle=Enum("VideoStyle", list(VIDEO_STYLES.values())),
    MindMapKind=Enum("MindMapKind", ["NOTE_BACKED", "INTERACTIVE"]),
)


class FakeClient:
    """Deterministic, fast, and never touches the network.

    Videos are written as small placeholder files; the pipeline doesn't request video in dry runs.
    """

    def __init__(self, delay: float = 0.01):
        self.delay = delay
        self.source_titles: dict[str, str] = {}
        self.notebooks = SimpleNamespace(create=self._create_notebook)
        self.sources = SimpleNamespace(add_file=self._add_file, add_text=self._add_text)
        self.chat = SimpleNamespace(ask=self._ask)
        self.mind_maps = SimpleNamespace(generate=self._generate_mind_map)
        self.artifacts = SimpleNamespace(
            generate_quiz=self._generate,
            generate_flashcards=self._generate,
            generate_audio=self._generate,
            generate_video=self._generate,
            wait_for_completion=self._wait,
            download_quiz=self._download_quiz,
            download_flashcards=self._download_cards,
            download_mind_map=self._download_mind_map,
            download_audio=self._download_audio,
            download_video=self._download_video,
        )

    async def __aenter__(self):
        return self

    async def refresh_auth(self, **kwargs):
        self.refreshes = getattr(self, "refreshes", 0) + 1

    async def __aexit__(self, *exc):
        return False

    async def _pause(self):
        await asyncio.sleep(self.delay)

    async def _create_notebook(self, title):
        await self._pause()
        return SimpleNamespace(id="dry-notebook")

    async def _add_file(self, notebook_id, path, **kwargs):
        await self._pause()
        source_id = f"source-{len(self.source_titles) + 1}"
        self.source_titles[source_id] = kwargs.get("title") or Path(path).stem
        return SimpleNamespace(id=source_id)

    async def _add_text(self, notebook_id, title, content, **kwargs):
        return await self._add_file(notebook_id, title, title=title)

    def _title_of(self, task_id) -> str:
        return self.source_titles.get(str(task_id).split("|")[0], "this chapter")

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        await self._pause()
        return SimpleNamespace(task_id=f"{source_ids[0]}|task")

    async def _wait(self, notebook_id, task_id, **kwargs):
        await self._pause()
        return SimpleNamespace(status="completed")

    async def _ask(self, notebook_id, prompt, source_ids=None, **kwargs):
        await self._pause()
        title = self.source_titles.get(source_ids[0], "this chapter")
        answer = _study(title) if "study material" in prompt else _graph(title)
        return SimpleNamespace(answer="```json\n" + json.dumps(answer) + "\n```")

    async def _generate_mind_map(self, notebook_id, source_ids=None, **kwargs):
        await self._pause()
        return SimpleNamespace(id=f"{source_ids[0]}|mindmap")

    async def _download_quiz(self, notebook_id, path, task_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps({"title": "Quiz", "questions": _quiz(self._title_of(task_id))}))
        return path

    async def _download_cards(self, notebook_id, path, task_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps({"title": "Cards", "cards": _cards(self._title_of(task_id))}))
        return path

    async def _download_mind_map(self, notebook_id, path, mind_map_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps(_mind_map(self._title_of(mind_map_id))))
        return path

    async def _download_audio(self, notebook_id, path, task_id=None, **kwargs):
        target = Path(path).with_suffix(".wav")
        target.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(target), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            tone = (
                struct.pack("<h", int(5000 * math.sin(2 * math.pi * f * i / 16000)))
                for f in (392, 523)
                for i in range(8000)
            )
            out.writeframes(b"".join(tone))
        return str(target)

    async def _download_video(self, notebook_id, path, task_id=None, **kwargs):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_bytes(b"placeholder video for tests")
        return path


class FakeStaleSessionClient(FakeClient):
    """Like FakeClient, but its session goes stale after the first item until `refresh_auth` is called,
    the way NotebookLM's does during a long podcast."""

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if ("audio_format" in kwargs or "video_format" in kwargs) and not getattr(self, "refreshes", 0):
            error = RuntimeError("The server rejected this request (unauthenticated).")
            error.rpc_code = 16
            raise error
        return await super()._generate(notebook_id, source_ids, **kwargs)


class FakeQuotaClient(FakeClient):
    """Like FakeClient, but every media request hits NotebookLM's daily limit."""

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs or "video_format" in kwargs:
            raise RuntimeError("RateLimitError: daily limit reached")
        return await super()._generate(notebook_id, source_ids, **kwargs)


def _study(title):
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


def _graph(title):
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


def _quiz(title):
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


def _cards(title):
    return [
        {"front": f"Main idea of {title}", "back": "A core trade-off and when it matters."},
        {"front": "First thing to check when it breaks", "back": "Simple engineering bugs."},
        {"front": "Why monitor?", "back": "Problems show up before users complain."},
    ]


def _mind_map(title):
    return {
        "name": title,
        "children": [
            {"name": "Foundations", "children": [{"name": "Key terms"}, {"name": "Core trade-off"}]},
            {"name": "In practice", "children": [{"name": "Patterns"}, {"name": "Failure modes"}]},
            {"name": "Takeaways"},
        ],
    }
