"""Making one item (quiz, video, ...) for one chapter with a NotebookLM client.

The client and its enums are passed in, so the real notebooklm-py library and the offline
fake (fake_client.py) run exactly the same code.
"""

import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

from . import activity, convert, prompts
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

# Word boundaries, so "page 429" or "after 1429s" never read as a limit.
_QUOTA = re.compile(
    r"rate[\s_-]?limit"
    r"|\bquota"
    r"|\blimit\s+(?:has\s+been\s+)?reached\b"
    r"|\b(?:daily|hourly|weekly|monthly|usage|request|generation)\s+limit\b"
    r"|\bresource[\s_]exhausted\b"
    r"|\btoo\s+many\s+requests\b"
    r"|\b(?:status|error|code|http(?:/[\d.]+)?)[\s:=]*429\b"
    r"|\b429\s+too\s+many\b",
    re.IGNORECASE,
)


class UnusableAnswer(ValueError):
    """NotebookLM answered, but not with something we can use."""


class NotebookLMBusy(RuntimeError):
    """NotebookLM didn't answer after several patient tries: the item waits for the next run."""

    try_later = True


_TRANSIENT = re.compile(
    r"timed?\s*out|timeout|deadline[\s_]exceeded|temporarily\s+unavailable|\bunavailable\b"
    r"|connection\s+(?:reset|refused|closed|aborted|error)|server\s+(?:error|disconnected)"
    r"|remote\s*protocol|bad\s+gateway|service\s+unavailable|gateway\s+time-?out"
    # A 502/503/504 only as an HTTP status, never "(char 504)" or "Chapter 503".
    r"|\b(?:status|error|code|http(?:/[\d.]+)?)[\s:=]*50[234]\b|\b50[234]\s+(?:service|bad|gateway)\b",
    re.IGNORECASE,
)
# Lasting problems: retrying the same request can't help (a feature turned off for this account, something
# that isn't there, a request NotebookLM rejects). The item fails, or auto makes it another way.
_LASTING_NAMES = (
    "FeatureUnavailable",
    "NotFound",
    "Validation",
    "Configuration",
    "Unsupported",
    "ClientError",
)
_LASTING = re.compile(
    r"\bgeneration\s+is\s+unavailable\b|\bfeature\s+(?:is\s+)?(?:unavailable|not\s+available)\b"
    r"|\bnot\s+found\b|\binvalid\s+argument\b",
    re.IGNORECASE,
)


def is_transient_error(error: BaseException) -> bool:
    """A hiccup worth waiting out (slow answer, dropped connection, busy server), not a limit or a sign-in."""
    if is_quota_error(error) or is_auth_error(error) or isinstance(error, (UnusableAnswer, ValueError)):
        return False  # ValueError: a JSONDecodeError or another answer we couldn't read; asking won't help
    if getattr(error, "try_later", False):
        return False  # already waited out patiently (NotebookLMBusy)
    names = " ".join(cls.__name__ for cls in type(error).__mro__)
    if any(k in names for k in _LASTING_NAMES) or _LASTING.search(str(error)):
        return False
    if isinstance(error, (TimeoutError, ConnectionError)):
        return True
    status = getattr(error, "status_code", None)
    if isinstance(status, int) and (status >= 500 or status == 408):
        return True
    if getattr(error, "rpc_code", None) in (4, 14, "4", "14", "DEADLINE_EXCEEDED", "UNAVAILABLE"):
        return True
    if any(
        k in names for k in ("Timeout", "ConnectError", "ReadError", "RemoteProtocolError", "NetworkError")
    ):
        return True
    return bool(_TRANSIENT.search(f"{type(error).__name__} {error}"))


def is_quota_error(error: BaseException) -> bool:
    from .models import QuotaError

    if isinstance(error, QuotaError):
        return True
    return bool(_QUOTA.search(f"{type(error).__name__} {error}"))


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
        self.pending: dict[tuple[int, str], str] = {}  # items asked for, until downloaded
        self.whole_waits: dict[tuple[int, str], int] = {}  # waits that ran their whole timeout, per item
        self.out_dir, self.media = out_dir, media

    async def make(self, task: str, chapter: dict) -> dict:
        """Return the fields to store on the chapter, e.g. {"quiz": [...]}. Raises on failure."""
        return await getattr(self, f"_{task}")(chapter, [chapter["sourceId"]])

    def _title(self, chapter: dict) -> str:
        return f"{chapter['n']:02d} {chapter['title']}"

    def _raw(self, chapter: dict, task: str) -> Path:
        return self.out_dir / "raw" / f"{chapter['n']:02d}-{task}.json"

    async def _ask(self, prompt: str, sources: list[str]):
        activity.report("Asking NotebookLM")
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
        quiz = convert.quiz(data)
        if not quiz:
            raise UnusableAnswer("NotebookLM's quiz had no usable questions")
        return {"quiz": quiz}

    async def _cards(self, chapter, sources):
        data = await self._generate_and_download(
            chapter,
            "cards",
            self.client.artifacts.generate_flashcards,
            self.client.artifacts.download_flashcards,
            sources,
        )
        cards = convert.flashcards(data)
        if not cards:
            raise UnusableAnswer("NotebookLM's flashcards had no usable cards")
        return {"cards": cards}

    async def _generate_and_download(self, chapter, task, generate, download, sources):
        async def ask():
            activity.report("Asking NotebookLM")
            return await generate(self.notebook_id, source_ids=sources)

        async def fetch(task_id):
            activity.report("NotebookLM is making it")
            await self.client.artifacts.wait_for_completion(self.notebook_id, task_id, timeout=LIGHT_TIMEOUT)
            raw = self._raw(chapter, task)
            await download(self.notebook_id, str(raw), task_id, output_format="json")
            return json.loads(raw.read_text(encoding="utf-8"))

        return await self._once(chapter, task, ask, fetch, LIGHT_TIMEOUT)

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
        async def ask():
            activity.report("Asking NotebookLM for the podcast")
            return await self.client.artifacts.generate_audio(
                self.notebook_id,
                source_ids=sources,
                language=self.media.language,
                instructions=self.media.instructions,
                audio_format=self.enums.AudioFormat[AUDIO_FORMATS[self.media.audio]],
                audio_length=self.enums.AudioLength[
                    audio_length(self.media.length, chapter_size(chapter, self.out_dir)).upper()
                ],
            )

        async def fetch(task_id):
            activity.report("NotebookLM is recording the podcast")
            await self.client.artifacts.wait_for_completion(self.notebook_id, task_id, timeout=AUDIO_TIMEOUT)
            activity.report("Downloading the podcast")
            target = self.out_dir / "media" / f"{chapter['n']:02d}-podcast.m4a"
            saved = await self.client.artifacts.download_audio(self.notebook_id, str(target), task_id)
            # NotebookLM gives no transcript; drop one an earlier engine left so it never mismatches.
            return {"audio": f"media/{Path(saved or target).name}", "transcript": None}

        return await self._once(chapter, "audio", ask, fetch, AUDIO_TIMEOUT)

    async def _video(self, chapter, sources):
        async def ask():
            activity.report("Asking NotebookLM for the video")
            return await self.client.artifacts.generate_video(
                self.notebook_id,
                source_ids=sources,
                language=self.media.language,
                instructions=self.media.instructions,
                video_format=self.enums.VideoFormat[VIDEO_FORMATS[self.media.video]],
                video_style=self.enums.VideoStyle[VIDEO_STYLES[self.media.style]],
            )

        async def fetch(task_id):
            activity.report("NotebookLM is making the video")
            await self.client.artifacts.wait_for_completion(self.notebook_id, task_id, timeout=VIDEO_TIMEOUT)
            activity.report("Downloading the video")
            target = self.out_dir / "media" / f"{chapter['n']:02d}-video.mp4"
            saved = await self.client.artifacts.download_video(self.notebook_id, str(target), task_id)
            if not saved or not Path(saved).exists():
                raise UnusableAnswer("No video was produced")
            return {"video": f"media/{Path(saved).name}", "explainer": None}

        return await self._once(chapter, "video", ask, fetch, VIDEO_TIMEOUT)

    async def _once(self, chapter, kind, ask, fetch, timeout: float):
        """Ask NotebookLM for an item once: if the session goes stale or a check times out while it's being
        made, the retry waits for the same one instead of asking (and spending NotebookLM's allowance) again.
        A wait that runs its whole `timeout` gets one more; after that the item waits for the next run."""
        key = (chapter["n"], kind)
        if key not in self.pending:
            self.pending[key] = (await ask()).task_id
        started = time.monotonic()
        try:
            result = await fetch(self.pending[key])
        except Exception as error:  # a stale session or a hiccup keeps the request for the retry
            if _whole_wait_ran_out(error, time.monotonic() - started, timeout):
                self.whole_waits[key] = self.whole_waits.get(key, 0) + 1
                if self.whole_waits[key] >= 2:
                    self.pending.pop(key, None)
                    self.whole_waits.pop(key, None)
                    raise NotebookLMBusy(
                        f"NotebookLM was still making it after waiting {2 * timeout / 60:.0f} minutes"
                    ) from error
            if not (is_auth_error(error) or is_transient_error(error)):
                self.pending.pop(key, None)
            raise
        self.pending.pop(key, None)
        self.whole_waits.pop(key, None)
        return result


def _whole_wait_ran_out(error: BaseException, seconds: float, timeout: float) -> bool:
    """The wait for an item ran its whole timeout (not one slow status check that timed out)."""
    names = " ".join(cls.__name__ for cls in type(error).__mro__)
    if "WaitTimeout" in names or "ArtifactTimeout" in names:
        return True
    return isinstance(error, TimeoutError) and seconds >= 0.9 * timeout
