"""Run the whole book pipeline: split, add sources, make every item, and keep the site up to date."""

import asyncio
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

from . import site
from .chapters import split_book
from .config import DEFAULT_INSTRUCTIONS, QUOTA_MESSAGE, SOURCE_TIMEOUT
from .notebook import ChapterMaker, MediaOptions, is_quota_error
from .selection import parse_selection
from .state import DONE, FAILED, SKIPPED, WAITING, WORKING, BookState

DRY_RUN_VIDEO_NOTE = "Dry runs don't make video."


@dataclass
class Options:
    book: Path
    out: Path
    chapters: str = "all"
    media: str = "1-3"
    audio: str = "deep-dive"
    video: str = "explainer"
    style: str = "kawaii"
    language: str = "en"
    instructions: str = DEFAULT_INSTRUCTIONS
    parallel: int = 2
    title: str | None = None
    retry: bool = False
    dry_run: bool = False
    log: Callable[[str], None] = field(default=print, repr=False)


def prepare_state(opts: Options) -> BookState:
    """Load the saved state, or split the book and create it; then mark what this run should make."""
    for sub in ("chapters", "media", "raw"):
        (opts.out / sub).mkdir(parents=True, exist_ok=True)
    state = BookState.load(opts.out / "state.json")
    if state is None:
        opts.log(f"Splitting {opts.book.name} into chapters…")
        chapters = split_book(opts.book, opts.out / "chapters")
        if not chapters:
            raise ValueError("Couldn't find any chapters in this book.")
        title = opts.title or opts.book.stem.replace("_", " ").replace("-", " ")
        state = BookState.create(
            opts.out / "state.json",
            title=title,
            source=opts.book.name,
            chapters=chapters,
            dry_run=opts.dry_run,
        )
    state.ensure_tasks()
    count = len(state.chapters)
    chosen, media = parse_selection(opts.chapters, count), parse_selection(opts.media, count)
    state.apply_selection(
        chosen,
        media,
        audio=opts.audio != "none",
        video=opts.video != "none" and not opts.dry_run,
        retry=opts.retry,
    )
    if opts.dry_run:
        for chapter in state.chapters:
            if chapter["tasks"]["video"]["status"] == SKIPPED and chapter["n"] in media:
                chapter["tasks"]["video"]["error"] = DRY_RUN_VIDEO_NOTE
    state.data["options"] = site_options(opts)
    state.save()
    opts.log(
        f"{count} chapters found. Working on {len(chosen)} of them; "
        f"podcast + video for {len(chosen & media)}."
    )
    return state


def site_options(opts: Options) -> dict:
    return {"audio": opts.audio, "video": opts.video, "style": opts.style, "language": opts.language}


async def run(opts: Options, client, enums: ModuleType) -> BookState:
    state = prepare_state(opts)
    site.build(opts.out, state, site_options(opts))
    async with client:
        await _add_sources(opts, state, client)
        maker = ChapterMaker(
            client,
            enums,
            state.data["notebookId"],
            opts.out,
            MediaOptions(opts.audio, opts.video, opts.style, opts.language, opts.instructions),
        )
        pending = state.pending()
        opts.log(f"Making {len(pending)} items, {opts.parallel} at a time.")
        limiter, quota_hit = asyncio.Semaphore(opts.parallel), set()
        await asyncio.gather(*(_make(opts, state, maker, limiter, quota_hit, c, t) for c, t in pending))
    site.build(opts.out, state, site_options(opts))
    return state


async def _add_sources(opts: Options, state: BookState, client) -> None:
    if not state.data["notebookId"]:
        notebook = await client.notebooks.create(f"NeuralLoop: {state.data['title']}"[:90])
        state.data["notebookId"] = notebook.id
        state.save()
    notebook_id = state.data["notebookId"]
    for chapter in state.chapters:
        if chapter["sourceId"] or not any(chapter["tasks"][t]["status"] != SKIPPED for t in chapter["tasks"]):
            continue
        file, title = opts.out / "chapters" / chapter["file"], f"{chapter['n']:02d} {chapter['title']}"[:90]
        if file.suffix == ".pdf":
            source = await client.sources.add_file(
                notebook_id, str(file), wait=True, wait_timeout=SOURCE_TIMEOUT, title=title
            )
        else:
            source = await client.sources.add_text(
                notebook_id, title, file.read_text(encoding="utf-8"), wait=True, wait_timeout=SOURCE_TIMEOUT
            )
        chapter["sourceId"] = source.id
        state.save()
        opts.log(f"  added chapter {chapter['n']}: {chapter['title']}")


async def _make(opts, state, maker, limiter, quota_hit, chapter, task) -> None:
    entry = chapter["tasks"][task]
    if task in quota_hit:
        entry.update(status=WAITING, error=QUOTA_MESSAGE)
        state.save()
        return
    async with limiter:
        if task in quota_hit:  # another item of this kind hit the limit while we waited
            entry.update(status=WAITING, error=QUOTA_MESSAGE)
            state.save()
            return
        entry["status"] = WORKING
        state.save()
        site.build(opts.out, state, site_options(opts))
        started = time.monotonic()
        try:
            chapter.update(await maker.make(task, chapter))
            entry.update(status=DONE, error="")
            opts.log(f"  ✓ chapter {chapter['n']} {task} ({time.monotonic() - started:.0f}s)")
        except Exception as error:
            if is_quota_error(error):
                quota_hit.add(task)
                entry.update(status=WAITING, error=QUOTA_MESSAGE)
                opts.log(
                    f"  … chapter {chapter['n']} {task}: NotebookLM limit reached; will continue next run"
                )
            else:
                entry.update(status=FAILED, error=f"{type(error).__name__}: {str(error)[:200]}")
                opts.log(f"  ✗ chapter {chapter['n']} {task}: {entry['error']}")
        state.save()
        site.build(opts.out, state, site_options(opts))
