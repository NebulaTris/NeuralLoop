"""The default engine: NotebookLM when it works, and the local engine (Ollama or your own AI) when it doesn't.

If NotebookLM can't start (not installed, not signed in), the whole run uses the local engine. If NotebookLM
fails or hits its limit on one item, that item is made locally instead, so a book is always finished.
"""

import asyncio

from .. import activity
from ..config import MEDIA_TASKS
from ..models import SetupError, safe_message
from ..notebook import GenerationFailed, is_auth_error, is_quota_error


class AutoEngine:
    def __init__(self, primary_factory, fallback_factory, log, fallback_parallel: int | None = None):
        """`fallback_parallel`: how many text items the fallback makes at once (1 for a model on this Mac),
        while NotebookLM keeps the run's own lanes; None leaves it to the lanes."""
        self._primary_factory, self._fallback_factory, self._log = primary_factory, fallback_factory, log
        self._fallback_text = asyncio.Semaphore(fallback_parallel) if fallback_parallel else None
        self.primary = self.fallback = None
        self._fallback_lock = asyncio.Lock()
        self._state = None
        self._why = ""
        self._fallback_error: SetupError | None = None  # the local engine couldn't be set up this run
        self._fallback_limited: set[str] = set()  # items the fallback hit its limit on: don't ask it again

    @property
    def name(self) -> str:
        if self.primary is not None:
            return self.primary.name
        return self.fallback.name if self.fallback is not None else "NotebookLM"

    async def __aenter__(self):
        try:
            self.primary = self._primary_factory()
            await self.primary.__aenter__()
        except Exception as error:  # any failure to open NotebookLM means: use the local engine
            self.primary, self._why = None, _short(error)
        return self

    async def __aexit__(self, *exc):
        for engine in (self.primary, self.fallback):
            if engine is not None:
                await engine.__aexit__(*exc)
        return False

    async def prepare(self, state) -> None:
        self._state = state
        if self.primary is not None:
            try:
                await self.primary.prepare(state)
            except Exception as error:  # not signed in, or a broken session: the book must still get made
                await self._drop_primary(error)
        if self.primary is None:
            fallback = await self._fallback_ready()
            self._log(f"NotebookLM isn't available ({self._why}); using {fallback.name} instead.")
        state.data["engine"] = "auto"
        state.save()

    async def make(self, task: str, chapter: dict) -> dict:
        primary_error: BaseException | None = None
        if self.primary is not None:
            try:
                return {**await self.primary.make(task, chapter), "_by": self.primary.name}
            except Exception as error:  # this item is made locally instead; the book always finishes
                if getattr(error, "stays_with_notebooklm", False) or (
                    task in MEDIA_TASKS
                    and (
                        is_quota_error(error)
                        or is_auth_error(error)
                        or getattr(error, "try_later", False)
                        or isinstance(error, GenerationFailed)
                    )
                ):
                    # People want NotebookLM's own podcasts and videos: wait for its limit to reset, or for
                    # it to answer (or take its session) again, rather than make them here; one NotebookLM
                    # said it couldn't make fails as NotebookLM's. A chapter NotebookLM couldn't take yet
                    # waits for it whatever the item.
                    raise _tagged(error, self.primary.name) from None
                if task in self._fallback_limited:
                    # The fallback is at its limit for this kind of item: this one fails (or waits) as
                    # NotebookLM's, and NotebookLM still tries the next ones.
                    raise _tagged(error, self.primary.name) from None
                try:
                    fallback = await self._fallback_ready()
                except SetupError:
                    # No local engine to hand it to: this item fails on its own; the rest carry on.
                    raise _tagged(error, self.primary.name) from None
                self._log(
                    f"  ↪ chapter {chapter['n']} {task}: NotebookLM couldn't ({_short(error)}); "
                    f"making it with {fallback.name}"
                )
                primary_error = error
        fallback = await self._fallback_ready()
        try:
            if primary_error is not None:  # NotebookLM tried this item and couldn't: the clock restarts
                step = f"NotebookLM couldn't, so {fallback.name} is making it"
                activity.report(step, by=fallback.name, restart=True)
            if self._fallback_text is None or task in MEDIA_TASKS:  # media have their own lane already
                return {**await fallback.make(task, chapter), "_by": fallback.name}
            async with self._fallback_text:
                return {**await fallback.make(task, chapter), "_by": fallback.name}
        except SetupError as error:
            if primary_error is None:
                raise  # the fallback is the whole run's engine: stop and say what to fix
            # The fallback stopped working mid-run (Ollama quit, a key was refused): NotebookLM's items carry
            # on, this one fails (or waits) as NotebookLM's, and the fallback isn't asked again this run.
            self._fallback_error = error
            raise _tagged(primary_error, self.primary.name) from None
        except Exception as error:  # say who failed, so a limit is reported under the right name
            if self.primary is not None and is_quota_error(error):
                self._fallback_limited.add(task)
            _tagged(error, fallback.name)
            raise

    async def _drop_primary(self, error: BaseException) -> None:
        self._why = _short(error)
        await self.primary.__aexit__(None, None, None)
        self.primary = None

    async def _fallback_ready(self):
        async with self._fallback_lock:
            if self._fallback_error is not None:
                raise self._fallback_error
            if self.fallback is None:
                try:
                    fallback = self._fallback_factory()
                    await fallback.__aenter__()
                    try:
                        await fallback.prepare(self._state)
                    except BaseException:
                        await fallback.__aexit__(None, None, None)
                        raise
                except SetupError as error:
                    self._fallback_error = error  # don't try setting it up again for every failing item
                    raise
                self.fallback = fallback
                if self.primary is not None:
                    # A mid-run fallback records its provider and model, but the book is still made by auto.
                    self._state.data["engine"] = "auto"
                    self._state.save()
        return self.fallback


def made_by(error: BaseException, default: str) -> str:
    """The engine that actually ran the item that raised `error` (auto can hand items to its fallback)."""
    return getattr(error, "engine_name", None) or default


def _tagged(error: BaseException, name: str) -> BaseException:
    error.engine_name = name
    return error


def _short(error: BaseException) -> str:
    text = str(error).strip().splitlines()[0] if str(error).strip() else type(error).__name__
    return safe_message(text, 120)
