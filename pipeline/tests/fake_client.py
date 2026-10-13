"""An offline stand-in for notebooklm-py with the same method names, for tests (never shipped)."""

import asyncio
import json
import math
import struct
import wave
from datetime import datetime
from enum import Enum
from pathlib import Path
from types import SimpleNamespace

from neuralloop_books.config import AUDIO_FORMATS, VIDEO_FORMATS, VIDEO_STYLES
from neuralloop_books.models.fake import cards as _cards
from neuralloop_books.models.fake import graph as _graph
from neuralloop_books.models.fake import mind_map as _mind_map
from neuralloop_books.models.fake import quiz as _quiz
from neuralloop_books.models.fake import study as _study

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
        self.notebooks_created = 0
        # Every quiz, deck, podcast and video asked for, as NotebookLM lists them (artifacts.list_*).
        self.made: list[SimpleNamespace] = []
        self.notebooks = SimpleNamespace(create=self._create_notebook)
        self.sources = SimpleNamespace(
            add_file=self._add_file,
            add_text=self._add_text,
            wait_until_ready=self._wait_until_ready,
            delete=self._delete_source,
        )
        self.chat = SimpleNamespace(ask=self._ask)
        self.mind_maps = SimpleNamespace(generate=self._generate_mind_map)
        self.artifacts = SimpleNamespace(
            generate_quiz=self._generate_quiz,
            generate_flashcards=self._generate_flashcards,
            generate_audio=self._generate,
            generate_video=self._generate,
            list_quizzes=self._lister("quiz"),
            list_flashcards=self._lister("flashcards"),
            list_audio=self._lister("audio"),
            list_video=self._lister("video"),
            wait_for_completion=self._wait,
            download_quiz=self._download_quiz,
            download_flashcards=self._download_cards,
            download_mind_map=self._download_mind_map,
            download_audio=self._download_audio,
            download_video=self._download_video,
        )

    async def __aenter__(self):
        self.opens = getattr(self, "opens", 0) + 1
        return self

    @property
    def refreshes(self) -> int:
        """How many times the run opened the session again after its first open."""
        return max(0, getattr(self, "opens", 0) - 1)

    async def __aexit__(self, *exc):
        return False

    async def _pause(self):
        await asyncio.sleep(self.delay)

    async def _create_notebook(self, title):
        await self._pause()
        self.notebooks_created += 1
        suffix = "" if self.notebooks_created == 1 else f"-{self.notebooks_created}"
        return SimpleNamespace(id=f"dry-notebook{suffix}")

    async def _add_file(self, notebook_id, path, **kwargs):
        await self._pause()
        source_id = f"source-{len(self.source_titles) + 1}"
        self.source_titles[source_id] = kwargs.get("title") or Path(path).stem
        return SimpleNamespace(id=source_id)

    async def _add_text(self, notebook_id, title, content, **kwargs):
        return await self._add_file(notebook_id, title, title=title)

    async def _wait_until_ready(self, notebook_id, source_id, **kwargs):
        await self._pause()
        return SimpleNamespace(id=source_id)

    async def _delete_source(self, notebook_id, source_id):
        await self._pause()
        self.source_titles.pop(source_id, None)

    def _title_of(self, task_id) -> str:
        return self.source_titles.get(str(task_id).split("|")[0], "this chapter")

    async def _generate_quiz(self, notebook_id, source_ids=None, **kwargs):
        return await self._generate(notebook_id, source_ids, _kind="quiz", **kwargs)

    async def _generate_flashcards(self, notebook_id, source_ids=None, **kwargs):
        return await self._generate(notebook_id, source_ids, _kind="flashcards", **kwargs)

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        await self._pause()
        return SimpleNamespace(task_id=self._record(source_ids, **kwargs))

    def _record(self, source_ids, **kwargs) -> str:
        """Remember a request the way NotebookLM lists it afterwards; returns its id."""
        kind = kwargs.get("_kind") or ("audio" if "audio_format" in kwargs else "video")
        task_id = f"{source_ids[0]}|{kind}-{len(self.made) + 1}"
        self.made.append(
            SimpleNamespace(id=task_id, kind=kind, source_ids=tuple(source_ids), created_at=datetime.now())
        )
        return task_id

    def _lister(self, kind):
        async def list_kind(notebook_id):
            await self._pause()
            return [artifact for artifact in self.made if artifact.kind == kind]

        return list_kind

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
        # Like notebooklm-py's note-backed MindMap: the note's id and the tree itself.
        tree = _mind_map(self.source_titles.get(source_ids[0], "this chapter"))
        return SimpleNamespace(id=f"{source_ids[0]}|mindmap", tree=tree)

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
    """Like FakeClient, but its session goes stale after the first item until the run opens it again,
    the way NotebookLM's does during a long podcast."""

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if ("audio_format" in kwargs or "video_format" in kwargs) and not getattr(self, "refreshes", 0):
            error = RuntimeError("The server rejected this request (unauthenticated).")
            error.rpc_code = 16
            raise error
        return await super()._generate(notebook_id, source_ids, **kwargs)


class FakeRotatedSessionClient(FakeClient):
    """A session another process rotated: every media request is refused until a client is opened afresh
    from the saved session. `shared` counts across the copies."""

    def __init__(self, shared: dict, delay: float = 0.0):
        super().__init__(delay)
        self.shared = shared
        shared["opened"] = shared.get("opened", 0) + 1
        self.dead = shared["opened"] == 1

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if self.dead and ("audio_format" in kwargs or "video_format" in kwargs):
            error = RuntimeError("The server rejected this request (unauthenticated).")
            error.rpc_code = 16
            raise error
        if "audio_format" in kwargs or "video_format" in kwargs:
            self.shared["generated"] = self.shared.get("generated", 0) + 1
        return await super()._generate(notebook_id, source_ids, **kwargs)


class FakeStaleWhileWaitingClient(FakeClient):
    """The session goes stale while NotebookLM records: the first wait is refused after the podcast was asked
    for, and the retry must wait for that same podcast instead of asking for (and paying for) another."""

    def __init__(self, delay: float = 0.0):
        super().__init__(delay)
        self.generated: list[str] = []
        self.waits = 0

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs:
            self.generated.append(source_ids[0])
        return await super()._generate(notebook_id, source_ids, **kwargs)

    async def _wait(self, notebook_id, task_id, **kwargs):
        self.waits += 1
        if self.waits == 1:
            error = RuntimeError("The server rejected this request (unauthenticated).")
            error.rpc_code = 16
            raise error
        return await super()._wait(notebook_id, task_id, **kwargs)


class FakeStaleTwiceWhileWaitingClient(FakeClient):
    """A long video sees Google's cookie rotate twice: the first `stale` status checks are refused, each after
    the session was opened again, and the item must keep refreshing (a few times) rather than give up."""

    def __init__(self, stale: int = 2, delay: float = 0.0):
        super().__init__(delay)
        self.stale, self.waits = stale, 0
        self.generated: list[str] = []

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs or "video_format" in kwargs:
            self.generated.append(f"{source_ids[0]}:{'audio' if 'audio_format' in kwargs else 'video'}")
        return await super()._generate(notebook_id, source_ids, **kwargs)

    async def _wait(self, notebook_id, task_id, **kwargs):
        self.waits += 1
        if self.waits <= self.stale:
            error = RuntimeError("The server rejected this request (unauthenticated).")
            error.rpc_code = 16
            raise error
        return await super()._wait(notebook_id, task_id, **kwargs)


class FakeSlowClient(FakeClient):
    """NotebookLM answering slowly: the first status check of every podcast and video times out (it's still
    being made), and the item must ride it out with the same podcast or video, asked for once."""

    def __init__(self, delay: float = 0.0):
        super().__init__(delay)
        self.generated: list[str] = []
        self.timed_out: set[str] = set()

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs or "video_format" in kwargs:
            self.generated.append(f"{source_ids[0]}:{'audio' if 'audio_format' in kwargs else 'video'}")
        return await super()._generate(notebook_id, source_ids, **kwargs)

    async def _wait(self, notebook_id, task_id, **kwargs):
        if task_id not in self.timed_out:
            self.timed_out.add(task_id)
            raise TimeoutError("Request timed out calling LIST_ARTIFACTS")
        return await super()._wait(notebook_id, task_id, **kwargs)


class WaitTimeoutError(TimeoutError):
    """notebooklm-py's name for a wait that ran its whole timeout (not one slow status check)."""


class FakeSlowQuizClient(FakeClient):
    """NotebookLM still making a quiz when the whole wait runs out, `timeouts` times in a row."""

    def __init__(self, timeouts: int = 1, delay: float = 0.0):
        super().__init__(delay)
        self.timeouts, self.quiz_waits = timeouts, 0
        self.quizzes_asked: list[str] = []
        self.artifacts.generate_quiz = self._generate_quiz

    async def _generate_quiz(self, notebook_id, source_ids=None, **kwargs):
        self.quizzes_asked.append(source_ids[0])
        return SimpleNamespace(task_id=f"{source_ids[0]}|quiz")

    async def _wait(self, notebook_id, task_id, **kwargs):
        if str(task_id).endswith("|quiz"):
            self.quiz_waits += 1
            if self.quiz_waits <= self.timeouts:
                raise WaitTimeoutError(f"Task {task_id} did not complete in {kwargs.get('timeout')}s")
        return await super()._wait(notebook_id, task_id, **kwargs)


class FakeDownClient(FakeClient):
    """NotebookLM not answering at all for podcasts and videos (every request times out)."""

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs or "video_format" in kwargs:
            self.asked = getattr(self, "asked", 0) + 1
            raise TimeoutError("Request timed out calling CREATE_ARTIFACT")
        return await super()._generate(notebook_id, source_ids, **kwargs)


class RPCTimeoutError(TimeoutError):
    """notebooklm-py's name for a request whose answer never came (it may still have been received)."""


class FakeLostReplyClient(FakeClient):
    """NotebookLM takes every request, but the answer to each quiz, deck, podcast and video request is lost
    on the way back (notebooklm-py re-raises it as an unconfirmed RPCTimeoutError)."""

    def __init__(self, delay: float = 0.0):
        super().__init__(delay)
        self.asked: list[str] = []

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        await self._pause()
        self._record(source_ids, **kwargs)
        self.asked.append(self.made[-1].kind)
        raise RPCTimeoutError("Request timed out calling CREATE_ARTIFACT")


class SourceTimeoutError(TimeoutError):
    """notebooklm-py's name: the source was made, but NotebookLM hadn't finished reading it in time."""

    def __init__(self, source_id: str, timeout: float = 900.0):
        self.source_id, self.timeout = source_id, timeout
        super().__init__(f"Source {source_id} not ready after {timeout:.1f}s")


class SourceProcessingError(Exception):
    """notebooklm-py's name: the source was made, but NotebookLM couldn't read it."""

    def __init__(self, source_id: str):
        self.source_id = source_id
        super().__init__(f"Source {source_id} failed to process")


class FakeSlowSourceClient(FakeClient):
    """NotebookLM takes chapter `only` as a source but is slow reading it: the add's own wait runs out, and
    so do the next `slow` waits for that source (or, `broken`, it can't read it at all)."""

    def __init__(self, only: int, slow: int = 0, broken: bool = False):
        super().__init__(delay=0)
        self.only, self.slow, self.broken = only, slow, broken
        self.uploads: list[str] = []
        self.ready_waits = 0
        self.reading: set[str] = set()
        self.deleted: list[str] = []

    async def _add_file(self, notebook_id, path, **kwargs):
        source = await super()._add_file(notebook_id, path, **kwargs)
        title = kwargs.get("title") or str(path)
        self.uploads.append(title)
        if title.startswith(f"{self.only:02d} "):
            self.reading.add(source.id)
            raise (SourceProcessingError if self.broken else SourceTimeoutError)(source.id)
        return source

    async def _wait_until_ready(self, notebook_id, source_id, **kwargs):
        if source_id in self.reading:
            self.ready_waits += 1
            if self.ready_waits <= self.slow:
                raise SourceTimeoutError(source_id)
            self.reading.discard(source_id)
        return await super()._wait_until_ready(notebook_id, source_id, **kwargs)

    async def _delete_source(self, notebook_id, source_id):
        self.deleted.append(source_id)
        await super()._delete_source(notebook_id, source_id)


class ArtifactDownloadError(Exception):
    """notebooklm-py's name: the item was made, but downloading it failed."""


class FakeDownloadFailsClient(FakeClient):
    """NotebookLM finishes every quiz, podcast and video, but downloading one of `kinds` fails its first
    `times` tries (an expired link, a 404)."""

    def __init__(self, kinds: tuple[str, ...], times: int = 1):
        super().__init__(delay=0)
        self.kinds, self.times = kinds, times
        self.download_tries: dict[str, int] = {}
        self.generated: list[str] = []

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        kind = kwargs.get("_kind") or ("audio" if "audio_format" in kwargs else "video")
        self.generated.append(f"{source_ids[0]}:{kind}")
        return await super()._generate(notebook_id, source_ids, **kwargs)

    def _failing(self, kind: str, task_id) -> None:
        if kind not in self.kinds:
            return
        tries = self.download_tries[task_id] = self.download_tries.get(task_id, 0) + 1
        if tries <= self.times:
            raise ArtifactDownloadError(f"Failed to download {kind}: HTTP 404")

    async def _download_quiz(self, notebook_id, path, task_id=None, **kwargs):
        self._failing("quiz", task_id)
        return await super()._download_quiz(notebook_id, path, task_id, **kwargs)

    async def _download_audio(self, notebook_id, path, task_id=None, **kwargs):
        self._failing("audio", task_id)
        return await super()._download_audio(notebook_id, path, task_id, **kwargs)

    async def _download_video(self, notebook_id, path, task_id=None, **kwargs):
        self._failing("video", task_id)
        return await super()._download_video(notebook_id, path, task_id, **kwargs)


class NotebookLimitError(Exception):
    """notebooklm-py's name: the account can't own another notebook."""


class FakeNotebookFullClient(FakeClient):
    """The account already owns as many notebooks as NotebookLM allows: creating one always fails."""

    def __init__(self):
        super().__init__(delay=0)
        self.creates = 0

    async def _create_notebook(self, title):
        self.creates += 1
        raise NotebookLimitError(
            "Cannot create notebook: account appears to be at or very near the NotebookLM notebook limit "
            "(100/100 owned notebooks reported). Delete old notebooks at https://notebooklm.google.com"
        )


class FakeQuotaClient(FakeClient):
    """Like FakeClient, but every media request hits NotebookLM's daily limit."""

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs or "video_format" in kwargs:
            raise RuntimeError("RateLimitError: daily limit reached")
        return await super()._generate(notebook_id, source_ids, **kwargs)


def opening(client):
    """`open_client` for a ready fake: every (re)open hands back the same client (counted in `opens`)."""

    async def open_client():
        return client

    return open_client
