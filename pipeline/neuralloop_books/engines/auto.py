"""The default engine: NotebookLM when it works, and the local engine (Ollama or your own AI) when it doesn't.

If NotebookLM can't start (not installed, not signed in), the whole run uses the local engine. If NotebookLM
fails or hits its limit on one item, that item is made locally instead, so a book is always finished.
"""

import asyncio


class AutoEngine:
    def __init__(self, primary_factory, fallback_factory, log):
        self._primary_factory, self._fallback_factory, self._log = primary_factory, fallback_factory, log
        self.primary = self.fallback = None
        self._fallback_lock = asyncio.Lock()
        self._state = None
        self._why = ""

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
        if self.primary is not None:
            try:
                return {**await self.primary.make(task, chapter), "_by": self.primary.name}
            except Exception as error:  # this item is made locally instead; the book always finishes
                fallback = await self._fallback_ready()
                self._log(
                    f"  ↪ chapter {chapter['n']} {task}: NotebookLM couldn't ({_short(error)}); "
                    f"making it with {fallback.name}"
                )
        fallback = await self._fallback_ready()
        return {**await fallback.make(task, chapter), "_by": fallback.name}

    async def _drop_primary(self, error: BaseException) -> None:
        self._why = _short(error)
        await self.primary.__aexit__(None, None, None)
        self.primary = None

    async def _fallback_ready(self):
        async with self._fallback_lock:
            if self.fallback is None:
                fallback = self._fallback_factory()
                await fallback.__aenter__()
                await fallback.prepare(self._state)
                self.fallback = fallback
        return self.fallback


def _short(error: BaseException) -> str:
    text = str(error).strip().splitlines()[0] if str(error).strip() else type(error).__name__
    return text[:120]
