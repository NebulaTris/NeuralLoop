"""Making one item (quiz, video, ...) for one chapter with a NotebookLM client.

The client and its enums are passed in, so the real notebooklm-py library and the offline
fake (fake_client.py) run exactly the same code.
"""

import json
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

from . import convert, prompts
from .chapters import chapter_size
from .config import (
    AUDIO_FORMATS,
    AUDIO_TIMEOUT,
    LIGHT_TIMEOUT,
    VIDEO_FORMATS,
    VIDEO_STYLES,
    VIDEO_TIMEOUT,
    audio_length,
)

_QUOTA_HINTS = (
    "ratelimit",
    "rate limit",
    "quota",
    "limit reached",
    "daily limit",
    "resource_exhausted",
    "429",
)


class UnusableAnswer(ValueError):
    """NotebookLM answered, but not with something we can use."""


def is_quota_error(error: BaseException) -> bool:
    from .models import QuotaError

    if isinstance(error, QuotaError):
        return True
    text = f"{type(error).__name__} {error}".lower()
    return any(hint in text for hint in _QUOTA_HINTS)


def is_auth_error(error: BaseException) -> bool:
    """NotebookLM's session went stale (it does during long podcasts); refreshing it usually fixes this."""
    if (
        getattr(error, "rpc_code", None) in (16, "16", "UNAUTHENTICATED")
        or type(error).__name__ == "AuthError"
    ):
        return True
    return "unauthenticated" in str(error).lower()


async def open_client(client_class):
    """notebooklm-py 0.8+ returns an async context manager; older builds return an awaitable."""
    client = client_class.from_storage()
    return client if hasattr(client, "__aenter__") else await client


@dataclass
class MediaOptions:
    audio: str
    video: str
    style: str
    language: str
    instructions: str
    length: str = "auto"


class ChapterMaker:
    def __init__(self, client, enums: ModuleType, notebook_id: str, out_dir: Path, media: MediaOptions):
        self.client, self.enums, self.notebook_id = client, enums, notebook_id
        self.out_dir, self.media = out_dir, media

    async def make(self, task: str, chapter: dict) -> dict:
        """Return the fields to store on the chapter, e.g. {"quiz": [...]}. Raises on failure."""
        return await getattr(self, f"_{task}")(chapter, [chapter["sourceId"]])

    def _title(self, chapter: dict) -> str:
        return f"{chapter['n']:02d} {chapter['title']}"

    def _raw(self, chapter: dict, task: str) -> Path:
        return self.out_dir / "raw" / f"{chapter['n']:02d}-{task}.json"

    async def _ask(self, prompt: str, sources: list[str]):
        answer = await self.client.chat.ask(self.notebook_id, prompt, source_ids=sources)
        return convert.loose_json(answer.answer)

    async def _study(self, chapter, sources):
        result = convert.study(await self._ask(prompts.STUDY.format(title=self._title(chapter)), sources))
        if not result:
            raise UnusableAnswer("NotebookLM's answer wasn't usable study material")
        return result

    async def _graph(self, chapter, sources):
        graph = convert.concept_graph(
            await self._ask(prompts.GRAPH.format(title=self._title(chapter)), sources)
        )
        if not graph:
            raise UnusableAnswer("NotebookLM's answer wasn't a usable concept graph")
        return {"graph": graph}

    async def _quiz(self, chapter, sources):
        data = await self._generate_and_download(
            chapter, "quiz", self.client.artifacts.generate_quiz, self.client.artifacts.download_quiz, sources
        )
        return {"quiz": convert.quiz(data)}

    async def _cards(self, chapter, sources):
        data = await self._generate_and_download(
            chapter,
            "cards",
            self.client.artifacts.generate_flashcards,
            self.client.artifacts.download_flashcards,
            sources,
        )
        return {"cards": convert.flashcards(data)}

    async def _generate_and_download(self, chapter, task, generate, download, sources):
        status = await generate(self.notebook_id, source_ids=sources)
        await self.client.artifacts.wait_for_completion(
            self.notebook_id, status.task_id, timeout=LIGHT_TIMEOUT
        )
        raw = self._raw(chapter, task)
        await download(self.notebook_id, str(raw), status.task_id, output_format="json")
        return json.loads(raw.read_text(encoding="utf-8"))

    async def _mindmap(self, chapter, sources):
        mind_map = await self.client.mind_maps.generate(
            self.notebook_id,
            source_ids=sources,
            kind=self.enums.MindMapKind.NOTE_BACKED,
            language=self.media.language,
        )
        raw = self._raw(chapter, "mindmap")
        await self.client.artifacts.download_mind_map(self.notebook_id, str(raw), mind_map.id)
        return {"mindmap": json.loads(raw.read_text(encoding="utf-8"))}

    async def _audio(self, chapter, sources):
        status = await self.client.artifacts.generate_audio(
            self.notebook_id,
            source_ids=sources,
            language=self.media.language,
            instructions=self.media.instructions,
            audio_format=self.enums.AudioFormat[AUDIO_FORMATS[self.media.audio]],
            audio_length=self.enums.AudioLength[
                audio_length(self.media.length, chapter_size(chapter, self.out_dir)).upper()
            ],
        )
        await self.client.artifacts.wait_for_completion(
            self.notebook_id, status.task_id, timeout=AUDIO_TIMEOUT
        )
        target = self.out_dir / "media" / f"{chapter['n']:02d}-podcast.m4a"
        saved = await self.client.artifacts.download_audio(self.notebook_id, str(target), status.task_id)
        # NotebookLM gives no transcript; drop one an earlier engine left so it never mismatches the audio.
        return {"audio": f"media/{Path(saved or target).name}", "transcript": None}

    async def _video(self, chapter, sources):
        status = await self.client.artifacts.generate_video(
            self.notebook_id,
            source_ids=sources,
            language=self.media.language,
            instructions=self.media.instructions,
            video_format=self.enums.VideoFormat[VIDEO_FORMATS[self.media.video]],
            video_style=self.enums.VideoStyle[VIDEO_STYLES[self.media.style]],
        )
        await self.client.artifacts.wait_for_completion(
            self.notebook_id, status.task_id, timeout=VIDEO_TIMEOUT
        )
        target = self.out_dir / "media" / f"{chapter['n']:02d}-video.mp4"
        saved = await self.client.artifacts.download_video(self.notebook_id, str(target), status.task_id)
        if not saved or not Path(saved).exists():
            raise UnusableAnswer("No video was produced")
        return {"video": f"media/{Path(saved).name}", "explainer": None}
