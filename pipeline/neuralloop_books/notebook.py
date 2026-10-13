"""Making one item (quiz, video, ...) for one chapter with a NotebookLM client.

The client and its enums are passed in, so the real notebooklm-py library and the offline
fake (fake_client.py) run exactly the same code.
"""

import asyncio
import contextlib
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

from . import activity, config, convert, prompts
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


class GenerationFailed(UnusableAnswer):
    """NotebookLM finished the request but says it couldn't make the item (not a limit)."""


class NotebookLMBusy(RuntimeError):
    """NotebookLM didn't answer after several patient tries: the item waits for the next run."""

    try_later = True


NOT_ANSWERING = "NotebookLM didn't answer this time; Pip will try again next run."
NOT_DOWNLOADED = "NotebookLM made it, but it couldn't be downloaded this time; Pip will try again next run."


class DownloadLater(RuntimeError):
    """NotebookLM made the item but downloading it failed: the next run downloads that same one (its id
    stays in state.json) instead of making it again, here or on the Mac. Other items carry on."""

    try_later = True
    only_this_item = True
    stays_with_notebooklm = True
    waiting_message = NOT_DOWNLOADED


class NotDownloaded(GenerationFailed):
    """NotebookLM made the item but it couldn't be downloaded on several runs: it fails as NotebookLM's (a
    podcast or video is never made on the Mac instead; auto may make a text item another way)."""


# NotebookLM's clock and ours may differ a little: an item found in the notebook counts as the one we asked
# for when it was made at most this long before we asked.
CLOCK_SLACK = 120.0
# How NotebookLM lists each kind of item it makes (notebooklm-py's artifacts.list_*).
_LISTS = {"quiz": "list_quizzes", "cards": "list_flashcards", "audio": "list_audio", "video": "list_video"}


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
    def __init__(
        self,
        client,
        enums: ModuleType,
        notebook_id: str | None,
        out_dir: Path,
        media: MediaOptions,
        save=None,
    ):
        """`save` writes the book's state, so an item asked for (`tasks.<item>.taskId`) is on disk at once
        and the next run waits for it instead of asking (and paying) again."""
        self.client, self.enums, self.notebook_id = client, enums, notebook_id
        self.pending: dict[tuple[int, str], str] = {}  # items asked for, until downloaded
        self.whole_waits: dict[tuple[int, str], int] = {}  # waits that ran their whole timeout, per item
        self.out_dir, self.media = out_dir, media
        self._save = save or (lambda: None)

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
            raw = self._raw(chapter, task)
            await download(self.notebook_id, str(raw), task_id, output_format="json")
            return json.loads(raw.read_text(encoding="utf-8"))

        return await self._once(chapter, task, ask, fetch, LIGHT_TIMEOUT, "NotebookLM is making it")

    async def _wait(self, task_id: str, timeout: float) -> None:
        _finished(await self.client.artifacts.wait_for_completion(self.notebook_id, task_id, timeout=timeout))

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
            activity.report("Downloading the podcast")
            target = self.out_dir / "media" / f"{chapter['n']:02d}-podcast.m4a"
            saved = await self.client.artifacts.download_audio(self.notebook_id, str(target), task_id)
            # NotebookLM gives no transcript; drop one an earlier engine left so it never mismatches.
            return {"audio": f"media/{Path(saved or target).name}", "transcript": None}

        return await self._once(
            chapter, "audio", ask, fetch, AUDIO_TIMEOUT, "NotebookLM is recording the podcast"
        )

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
            activity.report("Downloading the video")
            target = self.out_dir / "media" / f"{chapter['n']:02d}-video.mp4"
            saved = await self.client.artifacts.download_video(self.notebook_id, str(target), task_id)
            if not saved or not Path(saved).exists():
                raise UnusableAnswer("No video was produced")
            return {"video": f"media/{Path(saved).name}", "explainer": None}

        return await self._once(chapter, "video", ask, fetch, VIDEO_TIMEOUT, "NotebookLM is making the video")

    async def _once(self, chapter, kind, ask, fetch, timeout: float, making: str):
        """Ask NotebookLM for an item once: if the session goes stale or a check times out while it's being
        made, the retry waits for the same one instead of asking (and spending NotebookLM's allowance) again.
        A wait that runs its whole `timeout` gets one more; after that the item waits for the next run, which
        waits for that same one (its id is kept in state.json) instead of asking again. Once it's made,
        `fetch` downloads it; a download that fails is tried again by the next run, a few runs at most."""
        key = (chapter["n"], kind)
        entry = _entry(chapter, kind)
        if key not in self.pending:
            self.pending[key] = await self._resume_or_ask(chapter, kind, entry, ask)
        task_id = self.pending[key]
        started = time.monotonic()
        try:
            activity.report(making)
            await self._wait(task_id, timeout)
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
                _forget(entry)
            raise
        self.whole_waits.pop(key, None)
        try:
            result = await fetch(task_id)
        except Exception as error:  # it's made: a download that fails is tried again, never made again
            if is_auth_error(error) or is_transient_error(error):
                raise  # this run's retry waits for (already done) and downloads the same one
            self.pending.pop(key, None)
            tries = (_number(entry.get("downloadTries")) or 0) + 1
            if tries >= config.NOTEBOOKLM_DOWNLOAD_TRIES:
                _forget(entry)
                raise NotDownloaded(
                    f"NotebookLM made it, but it couldn't be downloaded after {tries} tries ({_short(error)})"
                ) from error
            entry["downloadTries"] = int(tries)
            with contextlib.suppress(OSError):  # the pipeline saves again as the item waits
                self._save()
            raise DownloadLater(f"NotebookLM made it, but downloading it failed ({_short(error)})") from error
        self.pending.pop(key, None)
        _forget(entry)
        return result

    async def _resume_or_ask(self, chapter, kind, entry: dict, ask) -> str:
        """The id of the item to wait for: one an earlier run asked for, else a new request."""
        if entry.get("taskId"):
            listed = await self._listed(kind)
            if listed is None or any(getattr(a, "id", None) == entry["taskId"] for a in listed):
                return entry["taskId"]  # still being made (or NotebookLM couldn't say): wait for it
            _forget(entry)  # NotebookLM no longer has it (deleted): ask afresh
        elif entry.get("requestedAt"):
            # An earlier run asked but never heard back: NotebookLM may have taken it anyway.
            asked_at = _number(entry["requestedAt"])
            found = await self._find(kind, chapter, asked_at) if asked_at is not None else None
            if found:
                self._remember(entry, found, asked_at)
                return found
        requested = time.time()
        self._remember(entry, None, requested)  # on disk before asking: a run killed mid-request looks first
        try:
            task_id = (await ask()).task_id
        except Exception as error:
            if not is_transient_error(error):
                _forget(entry)
                raise
            # The request may have reached NotebookLM though its answer never reached us (notebooklm-py calls
            # it "unconfirmed"): asking again could pay for the same podcast twice. Look for it instead.
            task_id = await self._find(kind, chapter, requested, look_again=True)
            if not task_id:
                raise NotebookLMBusy(
                    f"NotebookLM didn't confirm it got the request ({_short(error)}); "
                    "Pip will look for it next run"
                ) from error
        self._remember(entry, task_id, requested)
        return task_id

    async def _listed(self, kind: str) -> list | None:
        """NotebookLM's items of this kind in the notebook; None when it couldn't say."""
        lister = getattr(self.client.artifacts, _LISTS.get(kind, ""), None)
        if lister is None:
            return None
        try:
            return list(await lister(self.notebook_id))
        except Exception:  # listing is only a check: when it fails, nothing can be confirmed
            return None

    async def _find(self, kind: str, chapter: dict, since: float, look_again: bool = False) -> str | None:
        """The newest item of this kind for this chapter made since `since` (our request), if it's listed."""
        for attempt in range(2 if look_again else 1):
            if attempt:  # a new item can take a moment to show up in the notebook
                delays = config.NOTEBOOKLM_RETRY_DELAYS
                await asyncio.sleep(delays[0] if delays else 0)
            taken = set(self.pending.values())
            candidates = [
                (made, artifact.id)
                for artifact in (await self._listed(kind)) or []
                if (made := _created(artifact)) is not None
                and made >= since - CLOCK_SLACK
                and artifact.id not in taken
                # Only an item that says it was made from this chapter: one that doesn't say could be
                # another chapter's, and taking it would swap the two.
                and chapter.get("sourceId") in (getattr(artifact, "source_ids", None) or ())
            ]
            if candidates:
                return max(candidates)[1]
        return None

    def _remember(self, entry: dict, task_id: str | None, requested: float) -> None:
        if task_id:
            entry["taskId"] = task_id
        entry["requestedAt"] = round(requested)
        with contextlib.suppress(OSError):  # saving early is a nicety; the pipeline saves again later
            self._save()

    def forget_chapter(self, n: int) -> None:
        """The chapter's source (or the whole notebook) is gone: nothing asked for there can be collected."""
        for key in [k for k in self.pending if k[0] == n]:
            self.pending.pop(key, None)
            self.whole_waits.pop(key, None)


def _entry(chapter: dict, kind: str) -> dict:
    """The item's saved state (where its NotebookLM request is remembered); a throwaway dict without one."""
    tasks = chapter.get("tasks")
    entry = tasks.get(kind) if isinstance(tasks, dict) else None
    return entry if isinstance(entry, dict) else {}


def _forget(entry: dict) -> None:
    for key in ("taskId", "requestedAt", "downloadTries"):
        entry.pop(key, None)


def forget_requests(chapter: dict) -> None:
    """Drop every NotebookLM request remembered for this chapter (its source or notebook is gone)."""
    tasks = chapter.get("tasks")
    for entry in tasks.values() if isinstance(tasks, dict) else ():
        if isinstance(entry, dict):
            _forget(entry)


def _number(value) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _created(artifact) -> float | None:
    made = getattr(artifact, "created_at", None)
    if made is None:
        return None
    if isinstance(made, (int, float)):
        return float(made)
    try:
        return made.timestamp()  # a datetime (notebooklm-py 0.8's are timezone-aware UTC)
    except (AttributeError, ValueError, OverflowError, OSError):
        return None


def _finished(status) -> None:
    """notebooklm-py's wait returns how the request ended instead of raising: a failed one hit NotebookLM's
    limit (wait for it to reset) or NotebookLM couldn't make it (no download would work)."""
    outcome = getattr(status, "status", None)
    if outcome is None or outcome not in ("failed", "removed"):
        return
    reason = str(getattr(status, "error", None) or "").strip()
    limited = getattr(status, "is_rate_limited", None)
    if not isinstance(limited, bool):
        limited = getattr(status, "error_code", None) == "USER_DISPLAYABLE_ERROR" or bool(
            reason and _QUOTA.search(reason)
        )
    if limited:
        from .models import QuotaError

        raise QuotaError(f"NotebookLM's limit was reached ({reason or 'it said to try later'})")
    raise GenerationFailed(f"NotebookLM couldn't make it ({reason or 'it gave no reason'})")


def _short(error: BaseException) -> str:
    text = str(error).strip().splitlines()[0] if str(error).strip() else type(error).__name__
    return text[:100]


def _whole_wait_ran_out(error: BaseException, seconds: float, timeout: float) -> bool:
    """The wait for an item ran its whole timeout (not one slow status check that timed out)."""
    names = " ".join(cls.__name__ for cls in type(error).__mro__)
    if "WaitTimeout" in names or "ArtifactTimeout" in names:
        return True
    return isinstance(error, TimeoutError) and seconds >= 0.9 * timeout
