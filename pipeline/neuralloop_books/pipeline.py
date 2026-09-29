"""Run the whole book pipeline: split, prepare the engine, make every item, and keep the site up to date."""

import asyncio
import contextlib
import os
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from . import site
from .chapters import split_book
from .config import DEFAULT_INSTRUCTIONS, MEDIA_TASKS, quota_message
from .models import SetupError
from .notebook import is_quota_error
from .selection import parse_selection
from .state import DONE, FAILED, WAITING, WORKING, BookState


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
    media_parallel: int = 1  # podcasts and explainers, in their own lane so text items never wait behind them
    engine: str = "auto"
    provider: str = "auto"
    model: str | None = None
    context: int | None = None
    speech: str = "auto"
    voices: str | None = None
    base_url: str | None = None
    voice_quality: str = "fast"  # Rumik 4-bit ("fast", about twice as quick) or 8-bit ("best")
    # item -> aiconfig.ModelChoice, from the person's ai.json
    task_choices: dict = field(default_factory=dict)
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
    state.reset_interrupted()  # safe: the book's lock means no other run is working on it
    count = len(state.chapters)
    chosen, media = parse_selection(opts.chapters, count), parse_selection(opts.media, count)
    state.apply_selection(
        chosen,
        media,
        audio=opts.audio != "none",
        video=opts.video != "none",
        retry=opts.retry,
    )
    state.data["options"] = site_options(opts)
    state.save()
    opts.log(
        f"{count} chapters found. Working on {len(chosen)} of them; "
        f"podcast + video for {len(chosen & media)}."
    )
    return state


def site_options(opts: Options) -> dict:
    return {"audio": opts.audio, "video": opts.video, "style": opts.style, "language": opts.language}


async def run(opts: Options, engine) -> BookState:
    opts.out.mkdir(parents=True, exist_ok=True)
    with _book_lock(opts.out):
        return await _run(opts, engine)


@contextlib.contextmanager
def _book_lock(out: Path):
    """One run per book: a second run stops instead of racing the first on state.json."""
    lock = out / ".running"
    if lock.exists():
        try:
            pid = int(lock.read_text().strip() or 0)
            os.kill(pid, 0)  # raises if that run is gone
        except (ValueError, ProcessLookupError, PermissionError):
            pass  # a stale lock from a run that crashed or was quit
        else:
            raise ValueError("This book is already being prepared. Pip will keep going with that run.")
    lock.write_text(str(os.getpid()))
    try:
        yield
    finally:
        lock.unlink(missing_ok=True)


async def _run(opts: Options, engine) -> BookState:
    state = prepare_state(opts)
    site.build(opts.out, state, site_options(opts))
    async with engine:
        await engine.prepare(state)
        pending = state.pending()
        opts.log(f"Making {len(pending)} items with {engine.name}, chapter by chapter.")
        lanes = {"text": asyncio.Semaphore(opts.parallel), "media": asyncio.Semaphore(opts.media_parallel)}
        quota_hit: set[str] = set()
        await asyncio.gather(
            *(
                _make(opts, state, engine, lanes["media" if t in MEDIA_TASKS else "text"], quota_hit, c, t)
                for c, t in pending
            )
        )
    site.build(opts.out, state, site_options(opts))
    return state


async def _make(opts, state, engine, limiter, quota_hit, chapter, task) -> None:
    entry = chapter["tasks"][task]
    waiting = quota_message(engine.name)
    if task in quota_hit:
        entry.update(status=WAITING, error=waiting)
        state.save()
        return
    async with limiter:
        if task in quota_hit:  # another item of this kind hit the limit while we waited
            entry.update(status=WAITING, error=waiting)
            state.save()
            return
        entry["status"] = WORKING
        state.save()
        site.build(opts.out, state, site_options(opts))
        started = time.monotonic()
        try:
            result = await engine.make(task, chapter)
            entry["by"] = result.pop("_by", engine.name)  # which engine made it (auto can mix)
            chapter.update(result)
            entry.update(status=DONE, error="")
            opts.log(f"  ✓ chapter {chapter['n']} {task} ({time.monotonic() - started:.0f}s)")
        except SetupError:
            raise  # e.g. a revoked key: stop the run and say what to fix
        except Exception as error:  # one item failing must not stop the rest; it's recorded and retried later
            if is_quota_error(error):
                quota_hit.add(task)
                entry.update(status=WAITING, error=waiting)
                opts.log(
                    f"  … chapter {chapter['n']} {task}: {engine.name} limit reached; will continue next run"
                )
            else:
                entry.update(status=FAILED, error=f"{type(error).__name__}: {str(error)[:200]}")
                opts.log(f"  ✗ chapter {chapter['n']} {task}: {entry['error']}")
        state.save()
        site.build(opts.out, state, site_options(opts))
