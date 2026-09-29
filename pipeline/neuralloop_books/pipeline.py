"""Run the whole book pipeline: split, prepare the engine, make every item, and keep book.json up to date."""

import asyncio
import contextlib
import fcntl
import os
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from . import bookdata
from .chapters import split_book
from .config import DEFAULT_INSTRUCTIONS, MEDIA_TASKS, quota_message
from .engines.auto import made_by
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
    audio_length: str = "auto"  # "auto" = short podcasts for short chapters (quicker to make)
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
    state.data["options"] = book_options(opts)
    state.save()
    opts.log(
        f"{count} chapters found. Working on {len(chosen)} of them; "
        f"podcast + video for {len(chosen & media)}."
    )
    return state


def book_options(opts: Options) -> dict:
    return {"audio": opts.audio, "video": opts.video, "style": opts.style, "language": opts.language}


async def run(opts: Options, engine) -> BookState:
    opts.out.mkdir(parents=True, exist_ok=True)
    with _book_lock(opts.out):
        return await _run(opts, engine)


ALREADY_RUNNING = "This book is already being prepared. Pip will keep going with that run."


@contextlib.contextmanager
def _book_lock(out: Path):
    """One run per book: a second run stops instead of racing the first on state.json.

    The lock is the operating system's (flock) on `.running`, held for the whole run and released even when
    the process is killed, so a left-over file never blocks. The file also holds the run's process id.
    """
    path = out / ".running"
    while True:
        handle = open(path, "a+")  # noqa: SIM115 - held open for the whole run
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            raise ValueError(ALREADY_RUNNING) from None
        try:
            same_file = os.stat(path).st_ino == os.fstat(handle.fileno()).st_ino
        except FileNotFoundError:
            same_file = False
        if same_file:
            break
        handle.close()  # the run before us removed the file while we opened it: lock the new one
    try:
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
        yield
    finally:
        path.unlink(missing_ok=True)
        handle.close()


async def _run(opts: Options, engine) -> BookState:
    state = prepare_state(opts)
    bookdata.write(opts.out, state, book_options(opts))
    async with engine:
        await engine.prepare(state)
        pending = state.pending()
        opts.log(f"Making {len(pending)} items with {engine.name}, chapter by chapter.")
        lanes = {"text": asyncio.Semaphore(opts.parallel), "media": asyncio.Semaphore(opts.media_parallel)}
        quota_hit: dict[str, str] = {}  # item kind -> the engine that hit its limit
        tasks = [
            asyncio.ensure_future(
                _make(opts, state, engine, lanes["media" if t in MEDIA_TASKS else "text"], quota_hit, c, t)
            )
            for c, t in pending
        ]
        try:
            await asyncio.gather(*tasks)
        except BaseException:
            # e.g. a SetupError: stop every other item before the engine closes (TaskGroup needs 3.11).
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise
    bookdata.write(opts.out, state, book_options(opts))
    return state


async def _make(opts, state, engine, limiter, quota_hit, chapter, task) -> None:
    entry = chapter["tasks"][task]
    if task in quota_hit:
        entry.update(status=WAITING, error=quota_message(quota_hit[task]))
        state.save()
        return
    async with limiter:
        if task in quota_hit:  # another item of this kind hit the limit while we waited
            entry.update(status=WAITING, error=quota_message(quota_hit[task]))
            state.save()
            return
        entry["status"] = WORKING
        state.save()
        bookdata.write(opts.out, state, book_options(opts))
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
                who = made_by(error, engine.name)  # auto may have handed this item to its fallback
                quota_hit[task] = who
                entry.update(status=WAITING, error=quota_message(who))
                opts.log(f"  … chapter {chapter['n']} {task}: {who} limit reached; will continue next run")
            else:
                entry.update(status=FAILED, error=f"{type(error).__name__}: {str(error)[:200]}")
                opts.log(f"  ✗ chapter {chapter['n']} {task}: {entry['error']}")
        state.save()
        bookdata.write(opts.out, state, book_options(opts))
