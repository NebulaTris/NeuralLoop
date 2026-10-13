"""The NotebookLM engine: chapters become sources in one notebook; NotebookLM makes every item."""

import asyncio
import contextlib
from types import ModuleType

from .. import activity, config
from ..config import SOURCE_TIMEOUT, quota_message
from ..models import short_error
from ..notebook import (
    NOT_ANSWERING,
    ChapterMaker,
    GenerationFailed,
    MediaOptions,
    NotebookLMBusy,
    forget_requests,
    is_auth_error,
    is_quota_error,
    is_transient_error,
)
from ..state import TODO, WORKING, BookState

# A session that never recovers is opened afresh at most this many times per run (each reload keeps the old
# client open until the run ends, since an item may still be using it).
MAX_RELOADS_PER_RUN = 6


# NotebookLM took the chapter but hadn't finished reading it when the wait ran out.
STILL_READING = "NotebookLM is still reading this chapter; Pip will look again next run."


# The account owns as many notebooks as NotebookLM allows: say what to do about it.
NOTEBOOK_FULL = (
    "NotebookLM has no room for another notebook. Delete one you don't need in NotebookLM, "
    "and Pip will carry on next run."
)


class NotebookFull(RuntimeError):
    """NotebookLM won't make the book's notebook (the account is at its notebook limit): NotebookLM can't
    make anything for this book this run. Every item waits for the next run; auto makes the text items
    another way, and podcasts and videos wait for NotebookLM."""

    try_later = True
    waiting_message = NOTEBOOK_FULL


class NoSourceYet(RuntimeError):
    """NotebookLM wouldn't take this chapter this run (a limit, or it didn't answer): its items wait for the
    next run, which adds it again. Other chapters' items of the same kind carry on, and auto never makes them
    another way, since NotebookLM is still there."""

    try_later = True
    only_this_item = True
    stays_with_notebooklm = True

    def __init__(self, message: str, waiting_message: str, limit: bool):
        super().__init__(message)
        self.waiting_message, self.limit = waiting_message, limit


class SourceNotRead(GenerationFailed):
    """NotebookLM took the chapter but never finished reading it, over several runs and one fresh upload: its
    items fail (auto may make the text items another way; a podcast or video fails as NotebookLM's)."""


class NotebookLMEngine:
    name = "NotebookLM"

    def __init__(self, enums: ModuleType, opts, open_client):
        """`open_client`: a coroutine function that opens the saved session in the run loop (again whenever
        the session goes stale)."""
        self.client, self.enums, self.opts, self._open_client = None, enums, opts, open_client
        self.maker: ChapterMaker | None = None
        self._reload = asyncio.Lock()
        self._session = 0  # bumped each time the session is reloaded
        self._reloads = 0  # reloads this run, all items together
        self._retired: list = []  # earlier sessions, closed when the run ends (an item may still use one)
        self._state: BookState | None = None
        self._notebook_lock = asyncio.Lock()
        self._source_locks: dict[int, asyncio.Lock] = {}
        self._notebook_renewed = False  # a vanished notebook is made again once per run
        self._notebook_full: str | None = None  # why NotebookLM wouldn't make a notebook (asked once a run)
        self._sources_renewed: set[int] = set()  # a vanished source is added again once per chapter per run
        self._no_source: dict[int, BaseException] = {}  # chapters NotebookLM wouldn't take this run, and why
        self._read_counted: set[int] = set()  # chapters whose unread source was counted this run (readTries)

    async def __aenter__(self):
        # notebooklm-py hands back a context manager: the client is what entering it returns.
        self._context = await self._open_client()
        self.client = await self._context.__aenter__()
        return self

    async def __aexit__(self, *exc):
        for old in self._retired:
            with contextlib.suppress(Exception):  # an old session failing to close must not fail the run
                await old.__aexit__(None, None, None)
        return await self._context.__aexit__(*exc)

    async def prepare(self, state: BookState) -> None:
        """Make the book's notebook and add every chapter with work to do. A limit or NotebookLM not
        answering never stops the run: chapters already added carry on, the others wait for the next run.
        Only a sign-in problem goes up (auto then uses the local engine)."""
        self._state = state
        state.data.update(engine="notebooklm", provider="notebooklm", model="")
        opts = self.opts
        media = MediaOptions(
            opts.audio, opts.video, opts.style, opts.language, opts.instructions, opts.audio_length
        )
        self.maker = ChapterMaker(
            self.client, self.enums, state.data.get("notebookId"), opts.out, media, save=state.save
        )
        # Once NotebookLM is at its limit or doesn't answer, don't ask it to take more chapters this run. A
        # chapter it's still reading waits on its own: the chapters after it are still added.
        stuck: BaseException | None = None
        for chapter in state.chapters:
            if _source_ready(chapter) or not _has_work(chapter):
                continue
            if stuck is not None:
                self._no_source[chapter["n"]] = stuck
                continue
            try:
                await self._add_source(chapter)
            except Exception as error:  # sign-in problems go up; anything else stays with this chapter
                if is_auth_error(error) or _is_setup_error(error):
                    raise
                reason = _waiting(error)
                self._no_source[chapter["n"]] = reason or error
                if isinstance(error, NotebookFull):
                    stuck = error  # no notebook, so no chapter can be added this run
                    opts.log(f"  chapter {chapter['n']} waits: {NOTEBOOK_FULL}")
                if reason is not None:
                    if reason.waiting_message != STILL_READING:
                        stuck = reason
                    opts.log(f"  chapter {chapter['n']} waits: {reason.waiting_message}")

    async def make(self, task: str, chapter: dict) -> dict:
        if chapter["n"] in self._no_source:
            raise _again(self._no_source[chapter["n"]])
        delays = list(config.NOTEBOOKLM_RETRY_DELAYS)
        reloads = 0
        while True:
            session = self._session
            notebook = self._state.data.get("notebookId") if self._state is not None else None
            source = chapter.get("sourceId")
            try:
                if not _source_ready(chapter) and self._state is not None:
                    await self._add_again(chapter)
                return await self.maker.make(task, chapter)
            except Exception as error:  # a stale session or a hiccup is handled here; anything else goes up
                if _not_found(error, "Notebook") and self._state is not None:
                    if await self._renew_notebook(notebook):
                        continue
                    raise
                if _not_found(error, "Source") and self._state is not None and source:
                    if await self._renew_source(chapter, source):
                        continue
                    raise
                if is_auth_error(error):
                    # A long video can see the cookie rotate more than once: reload whenever it went stale
                    # during this attempt, a few times per item (and a few more per run).
                    if reloads < config.NOTEBOOKLM_SESSION_RELOADS and await self._fresh_session(session):
                        reloads += 1
                        continue
                    if task in config.MEDIA_TASKS:
                        # A podcast or video waits for NotebookLM (next run), never made on the Mac instead.
                        raise NotebookLMBusy(
                            f"NotebookLM kept refusing the session ({short_error(error)})"
                        ) from error
                    raise
                if not is_transient_error(error):
                    raise
                if not delays:
                    tries = len(config.NOTEBOOKLM_RETRY_DELAYS) + 1
                    raise NotebookLMBusy(
                        f"NotebookLM didn't answer ({short_error(error)}) after {tries} tries"
                    ) from error
                pause = delays.pop(0)
                activity.report(f"NotebookLM is slow right now, trying again in {pause} s")
                await asyncio.sleep(pause)

    # ---- the notebook and its sources ----

    async def _ensure_notebook(self) -> str:
        """The book's notebook, made now if it has none. Call with `_notebook_lock` held."""
        state = self._state
        if not state.data.get("notebookId"):
            if self._notebook_full is not None:  # asked once this run already: don't ask again
                raise NotebookFull(self._notebook_full)
            title = f"NeuralLoop: {state.data['title']}"[:90]
            try:
                notebook = await self._patiently(lambda: self.client.notebooks.create(title))
            except Exception as error:  # only a full account is turned into waiting; the rest goes up
                if not _named(error, "NotebookLimitError"):
                    raise
                self._notebook_full = f"NotebookLM wouldn't make a notebook ({short_error(error)})"
                raise NotebookFull(self._notebook_full) from error
            state.data["notebookId"] = notebook.id
            state.save()
        self.maker.notebook_id = state.data["notebookId"]
        return state.data["notebookId"]

    async def _add_source(self, chapter: dict) -> None:
        """Add the chapter to the notebook (once, however many of its items ask at the same time). A source
        NotebookLM made but hadn't finished reading is kept (`sourceReady: false`) and waited for by the
        next run, never uploaded again: that would leave duplicates in the notebook."""
        lock = self._source_locks.setdefault(chapter["n"], asyncio.Lock())
        async with lock:
            while not _source_ready(chapter):
                async with self._notebook_lock:
                    notebook = await self._ensure_notebook()
                made = chapter.get("sourceId")
                try:
                    if made:
                        await self._patiently(
                            lambda at=notebook, made=made: self._until_ready(at, made), _nothing_made
                        )
                    else:
                        source = await self._patiently(
                            lambda at=notebook: self._upload(at, chapter), _nothing_made
                        )
                        chapter["sourceId"] = source.id
                except Exception as error:  # a source made but not yet read is kept; a vanished one replaced
                    made = made or _made_source(error)
                    if made and _source_unreadable(error):
                        await self._drop_source(notebook, chapter, made)
                        raise
                    if made and _made_source(error):  # made, but NotebookLM hasn't finished reading it
                        if not chapter.get("sourceId"):
                            chapter["sourceId"], chapter["sourceReady"] = made, False
                        if self._unread_too_long(chapter):
                            again = not chapter.get("readAgain")
                            await self._drop_source(notebook, chapter, made)
                            if again:
                                # Once more from the start: a fresh upload may be read where this one wasn't.
                                chapter.update(readAgain=True, readTries=config.NOTEBOOKLM_READ_TRIES)
                                self._state.save()
                                self.opts.log(
                                    f"  chapter {chapter['n']}: NotebookLM never finished reading it; "
                                    "adding it once more"
                                )
                                continue
                            raise SourceNotRead(
                                "NotebookLM never finished reading this chapter, even when it was added again"
                            ) from error
                        self._state.save()
                    if _not_found(error, "Notebook") and await self._renew_notebook(notebook):
                        continue
                    if _not_found(error, "Source") and made and chapter["n"] not in self._sources_renewed:
                        self._sources_renewed.add(chapter["n"])
                        self._forget_source(chapter)
                        continue
                    raise
                for key in ("sourceReady", "readTries", "readAgain"):
                    chapter.pop(key, None)
                self._state.save()
                self.opts.log(f"  added chapter {chapter['n']}: {chapter['title']}")

    def _unread_too_long(self, chapter: dict) -> bool:
        """Count this run (once) among those the chapter's source stayed unread; True once that's
        NOTEBOOKLM_READ_TRIES runs."""
        if chapter["n"] not in self._read_counted:
            self._read_counted.add(chapter["n"])
            tries = chapter.get("readTries")
            tries = tries if isinstance(tries, int) and not isinstance(tries, bool) else 0
            chapter["readTries"] = tries + 1
        return chapter["readTries"] >= config.NOTEBOOKLM_READ_TRIES

    async def _until_ready(self, notebook: str, source_id: str) -> None:
        await self.client.sources.wait_until_ready(notebook, source_id, timeout=SOURCE_TIMEOUT)

    async def _drop_source(self, notebook: str, chapter: dict, source_id: str) -> None:
        """NotebookLM couldn't read the source it made: take it out of the notebook, so a later retry
        starts clean, and forget it here."""
        with contextlib.suppress(Exception):  # tidying up is best effort; the chapter fails either way
            await self.client.sources.delete(notebook, source_id)
        self._forget_source(chapter)

    def _forget_source(self, chapter: dict) -> None:
        chapter["sourceId"] = None
        for key in ("sourceReady", "readTries", "readAgain"):
            chapter.pop(key, None)
        forget_requests(chapter)
        self.maker.forget_chapter(chapter["n"])
        self._state.save()

    async def _add_again(self, chapter: dict) -> None:
        """A chapter whose source went away mid-run: a limit or a hiccup leaves just this item waiting."""
        try:
            await self._add_source(chapter)
        except Exception as error:  # only a limit or a hiccup is turned into waiting; the rest goes up as is
            reason = _waiting(error)
            if reason is not None:
                if reason.waiting_message == STILL_READING:
                    # The chapter's other items wait too, without each waiting out NotebookLM's reading.
                    self._no_source[chapter["n"]] = reason
                raise reason from error
            raise

    async def _upload(self, notebook: str, chapter: dict):
        file = self.opts.out / "chapters" / chapter["file"]
        title = f"{chapter['n']:02d} {chapter['title']}"[:90]
        if file.suffix == ".pdf":
            return await self.client.sources.add_file(
                notebook, str(file), wait=True, wait_timeout=SOURCE_TIMEOUT, title=title
            )
        return await self.client.sources.add_text(
            notebook, title, file.read_text(encoding="utf-8"), wait=True, wait_timeout=SOURCE_TIMEOUT
        )

    async def _renew_notebook(self, failed: str | None) -> bool:
        """The notebook is gone (deleted, or another Google account signed in): make a new one, once per
        run. Every chapter is added again when one of its items next needs it. False: don't try again."""
        async with self._notebook_lock:
            state = self._state
            if state.data.get("notebookId") != failed:
                return True  # another item already made a new one
            if self._notebook_renewed:
                return False
            self._notebook_renewed = True
            self.opts.log("  NotebookLM's notebook for this book is gone; making a new one")
            state.data["notebookId"] = None
            for chapter in state.chapters:
                chapter["sourceId"] = None
                chapter.pop("sourceReady", None)
                forget_requests(chapter)
                self.maker.forget_chapter(chapter["n"])
            state.save()
            await self._ensure_notebook()
            return True

    async def _renew_source(self, chapter: dict, failed: str) -> bool:
        """The chapter's source is gone from the notebook: add it again, once per chapter per run."""
        lock = self._source_locks.setdefault(chapter["n"], asyncio.Lock())
        async with lock:
            if chapter.get("sourceId") != failed:
                return True  # another item already dealt with it
            if chapter["n"] in self._sources_renewed:
                return False
            self._sources_renewed.add(chapter["n"])
            self._forget_source(chapter)
        return True  # the next attempt adds it again

    async def _patiently(self, call, retry=is_transient_error):
        """Run `call`, riding out hiccups (the errors `retry` accepts) the way items do; NotebookLMBusy when
        NotebookLM never answers."""
        delays = list(config.NOTEBOOKLM_RETRY_DELAYS)
        while True:
            try:
                return await call()
            except Exception as error:  # only hiccups are retried; everything else goes up as it is
                if not retry(error):
                    raise
                if not delays:
                    tries = len(config.NOTEBOOKLM_RETRY_DELAYS) + 1
                    raise NotebookLMBusy(
                        f"NotebookLM didn't answer ({short_error(error)}) after {tries} tries"
                    ) from error
                await asyncio.sleep(delays.pop(0))

    # ---- the session ----

    async def _fresh_session(self, failed: int) -> bool:
        """Google's session cookie rotates whenever another NotebookLM process (the app's usage check, a
        second run) opens the saved session, and the rotated cookie is saved to disk; this run's copy is then
        refused, and refreshing that copy can't help. So open the saved session again, once for every item
        that saw it go, and at most MAX_RELOADS_PER_RUN times a run. False when that's used up."""
        async with self._reload:
            if self._session != failed:  # another item already reloaded it while this one was failing
                return True
            if self._reloads >= MAX_RELOADS_PER_RUN:
                return False
            self._reloads += 1
            context = await self._open_client()
            client = await context.__aenter__()
            self._retired.append(self._context)
            self._context, self.client = context, client
            if self.maker is not None:
                self.maker.client = client
            self._session += 1
            return True


def _source_ready(chapter: dict) -> bool:
    """The chapter is in the notebook and NotebookLM has read it (a source saved before `sourceReady`
    existed counts as read)."""
    return bool(chapter.get("sourceId")) and chapter.get("sourceReady") is not False


def _made_source(error: BaseException) -> str | None:
    """The id of the source NotebookLM made before this error (notebooklm-py's SourceTimeoutError: not read
    in time; SourceProcessingError: it couldn't read it), else None: nothing was made."""
    names = {cls.__name__ for cls in type(error).__mro__}
    if names & {"SourceTimeoutError", "SourceProcessingError"}:
        source_id = getattr(error, "source_id", None)
        return source_id if isinstance(source_id, str) and source_id else None
    return None


def _source_unreadable(error: BaseException) -> bool:
    return any(cls.__name__ == "SourceProcessingError" for cls in type(error).__mro__)


def _nothing_made(error: BaseException) -> bool:
    """A hiccup worth trying again, but never one after NotebookLM made the source: that would add it
    twice (and its wait already ran its whole timeout)."""
    return is_transient_error(error) and _made_source(error) is None


def _has_work(chapter: dict) -> bool:
    return any(entry.get("status") in (TODO, WORKING) for entry in chapter["tasks"].values())


def _not_found(error: BaseException, what: str) -> bool:
    """notebooklm-py's NotebookNotFoundError / SourceNotFoundError (by name, as for its other errors)."""
    return _named(error, f"{what}NotFoundError")


def _named(error: BaseException, name: str) -> bool:
    """The error is notebooklm-py's `name` (matched by name, so the library stays optional)."""
    return any(cls.__name__ == name for cls in type(error).__mro__)


def _is_setup_error(error: BaseException) -> bool:
    from ..models import SetupError

    return isinstance(error, SetupError)


def _waiting(error: BaseException) -> NoSourceYet | None:
    """A chapter NotebookLM wouldn't take because of a limit or a hiccup waits; None for anything else."""
    if isinstance(error, NotebookFull):
        return None  # goes up as it is: auto makes the text items another way
    if is_quota_error(error):
        return NoSourceYet(short_error(error), quota_message("NotebookLM"), limit=True)
    if _made_source(error) and not _source_unreadable(error):
        return NoSourceYet(short_error(error), STILL_READING, limit=False)
    if getattr(error, "try_later", False) or is_transient_error(error):
        return NoSourceYet(short_error(error), NOT_ANSWERING, limit=False)
    return None


def _again(error: BaseException) -> BaseException:
    """A fresh copy of the reason a chapter has no source, for each of its items."""
    if isinstance(error, NoSourceYet):
        return NoSourceYet(str(error), error.waiting_message, error.limit)
    if isinstance(error, (GenerationFailed, NotebookFull)):  # auto treats each copy as the original
        return type(error)(str(error))
    return RuntimeError(f"NotebookLM wouldn't take this chapter ({short_error(error)})")
