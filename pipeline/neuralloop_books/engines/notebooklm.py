"""The NotebookLM engine: chapters become sources in one notebook; NotebookLM makes every item."""

import asyncio
import contextlib
from types import ModuleType

from .. import activity, config
from ..config import SOURCE_TIMEOUT
from ..notebook import ChapterMaker, MediaOptions, NotebookLMBusy, is_auth_error, is_transient_error
from ..state import SKIPPED, BookState


class NotebookLMEngine:
    name = "NotebookLM"

    def __init__(self, client, enums: ModuleType, opts, open_client=None):
        """Pass a ready `client`, or `open_client`: a coroutine function that opens one in the run loop."""
        self.client, self.enums, self.opts, self._open_client = client, enums, opts, open_client
        self.maker: ChapterMaker | None = None
        self._reload = asyncio.Lock()
        self._session = 0  # bumped each time the session is reloaded
        self._retired: list = []  # earlier sessions, closed when the run ends (an item may still use one)

    async def __aenter__(self):
        # notebooklm-py hands back a context manager: the client is what entering it returns.
        self._context = self.client if self.client is not None else await self._open_client()
        self.client = await self._context.__aenter__()
        return self

    async def __aexit__(self, *exc):
        for old in self._retired:
            with contextlib.suppress(Exception):  # an old session failing to close must not fail the run
                await old.__aexit__(None, None, None)
        return await self._context.__aexit__(*exc)

    async def prepare(self, state: BookState) -> None:
        state.data.update(engine="notebooklm", provider="notebooklm", model="")
        opts, client = self.opts, self.client
        if not state.data["notebookId"]:
            notebook = await client.notebooks.create(f"NeuralLoop: {state.data['title']}"[:90])
            state.data["notebookId"] = notebook.id
            state.save()
        notebook_id = state.data["notebookId"]
        for chapter in state.chapters:
            if chapter["sourceId"] or not any(
                chapter["tasks"][t]["status"] != SKIPPED for t in chapter["tasks"]
            ):
                continue
            file, title = (
                opts.out / "chapters" / chapter["file"],
                f"{chapter['n']:02d} {chapter['title']}"[:90],
            )
            if file.suffix == ".pdf":
                source = await client.sources.add_file(
                    notebook_id, str(file), wait=True, wait_timeout=SOURCE_TIMEOUT, title=title
                )
            else:
                source = await client.sources.add_text(
                    notebook_id,
                    title,
                    file.read_text(encoding="utf-8"),
                    wait=True,
                    wait_timeout=SOURCE_TIMEOUT,
                )
            chapter["sourceId"] = source.id
            state.save()
            opts.log(f"  added chapter {chapter['n']}: {chapter['title']}")
        media = MediaOptions(
            opts.audio, opts.video, opts.style, opts.language, opts.instructions, opts.audio_length
        )
        self.maker = ChapterMaker(client, self.enums, notebook_id, opts.out, media)

    async def make(self, task: str, chapter: dict) -> dict:
        delays = list(config.NOTEBOOKLM_RETRY_DELAYS)
        reloaded = False
        while True:
            session = self._session
            try:
                return await self.maker.make(task, chapter)
            except Exception as error:  # a stale session or a hiccup is handled here; anything else goes up
                if is_auth_error(error) and not reloaded:
                    reloaded = True
                    await self._fresh_session(session)
                    continue
                if not is_transient_error(error):
                    raise
                if not delays:
                    tries = len(config.NOTEBOOKLM_RETRY_DELAYS) + 1
                    raise NotebookLMBusy(
                        f"NotebookLM didn't answer ({_short(error)}) after {tries} tries"
                    ) from error
                pause = delays.pop(0)
                activity.report(f"NotebookLM is slow right now, trying again in {pause} s")
                await asyncio.sleep(pause)

    async def _fresh_session(self, failed: int) -> None:
        """Google's session cookie rotates whenever another NotebookLM process (the app's usage check, a
        second run) opens the saved session, and the rotated cookie is saved to disk; this run's copy is then
        refused, and refreshing that copy can't help. So open the saved session again, once for every item
        that saw it go."""
        async with self._reload:
            if self._session != failed:  # another item already reloaded it while this one was failing
                return
            if self._open_client is None:
                if hasattr(self.client, "refresh_auth"):
                    await self.client.refresh_auth()
            else:
                context = await self._open_client()
                client = await context.__aenter__()
                self._retired.append(self._context)
                self._context, self.client = context, client
                if self.maker is not None:
                    self.maker.client = client
            self._session += 1


def _short(error: BaseException) -> str:
    text = str(error).strip().splitlines()[0] if str(error).strip() else type(error).__name__
    return text[:100]
