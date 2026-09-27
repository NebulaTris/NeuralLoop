"""The NotebookLM engine: chapters become sources in one notebook; NotebookLM makes every item."""

from types import ModuleType

from ..config import SOURCE_TIMEOUT
from ..notebook import ChapterMaker, MediaOptions
from ..state import SKIPPED, BookState


class NotebookLMEngine:
    name = "NotebookLM"

    def __init__(self, client, enums: ModuleType, opts):
        self.client, self.enums, self.opts = client, enums, opts
        self.maker: ChapterMaker | None = None

    async def __aenter__(self):
        await self.client.__aenter__()
        return self

    async def __aexit__(self, *exc):
        return await self.client.__aexit__(*exc)

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
        media = MediaOptions(opts.audio, opts.video, opts.style, opts.language, opts.instructions)
        self.maker = ChapterMaker(client, self.enums, notebook_id, opts.out, media)

    async def make(self, task: str, chapter: dict) -> dict:
        return await self.maker.make(task, chapter)
