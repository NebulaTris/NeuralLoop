"""What's being made right now, for the app's progress loader: `activity.json` in the book folder.

    {"updated": ms, "ended": false,
     "items": [{"n": 1, "item": "audio", "by": "NotebookLM", "step": "NotebookLM is recording the podcast",
                "started": ms, "updated": ms, "done": 3 | null, "total": 12 | null,
                "fraction": 0-1 | null, "expected": seconds | null}],
     "queue": [{"n": 1, "item": "video"}, ...]}

An item's own code reports its steps with `report(...)`: it finds its item through a context variable, so no
arguments are threaded through the engines, and it works from `asyncio.to_thread` too. `expected` comes
from how long the same maker took for the same kind of item recently (`timings`, kept in state.json), else a
sensible default; local podcasts and videos report `done`/`total` and one overall `fraction` across their
stages instead. The file is written atomically, at
most every half second unless the step changes, and cleared (`ended: true`) when the run ends.
"""

import contextlib
import json
import os
import statistics
import threading
import time
from collections.abc import Callable
from contextvars import ContextVar, Token
from pathlib import Path

from .config import MEDIA_TASKS

DEFAULT_SECONDS: dict[tuple[str, str], int | None] = {
    ("NotebookLM", "audio"): 480,  # NotebookLM's podcasts usually take 5-10 minutes
    ("NotebookLM", "video"): 720,
    ("NotebookLM", "text"): 90,
    ("local", "text"): 120,
    ("local", "audio"): None,  # lines voiced / total instead
    ("local", "video"): None,  # slides voiced, then frames drawn, instead
}
KEEP_TIMINGS = 10
WRITE_EVERY = 0.5

_current: ContextVar["tuple[Activity, int, str] | None"] = ContextVar("neuralloop_activity", default=None)


class Activity:
    def __init__(self, out: Path, timings: dict[str, list[float]], clock: Callable[[], float] = time.time):
        self.path = out / "activity.json"
        self.timings = {k: list(v) for k, v in timings.items()}
        self._clock = clock
        self._lock = threading.Lock()
        self._items: dict[tuple[int, str], dict] = {}
        self._queue: list[tuple[int, str]] = []
        self._last_write = 0.0

    # ---- what the pipeline calls ----

    def queue(self, pending: list[tuple[int, str]]) -> None:
        """Everything still to make this run, in the order it'll be made."""
        with self._lock:
            self._queue = list(pending)

    def begin(self, n: int, item: str, by: str) -> Token:
        now = self._ms()
        with self._lock:
            self._queue = [q for q in self._queue if q != (n, item)]
            self._items[(n, item)] = {
                "n": n,
                "item": item,
                "by": by,
                "step": "",
                "started": now,
                "updated": now,
                "done": None,
                "total": None,
                "fraction": None,
                "expected": self.expected(by, item),
            }
            self._write(now, force=True)
        return _current.set((self, n, item))

    def end(self, n: int, item: str, seconds: float, ok: bool, token: Token | None = None) -> None:
        with self._lock:
            entry = self._items.pop((n, item), None)
            if ok and entry is not None:
                key = f"{entry['by']}:{item}"
                self.timings[key] = [*self.timings.get(key, []), round(seconds)][-KEEP_TIMINGS:]
            self._write(self._ms(), force=True)
        if token is not None:
            _current.reset(token)

    def close(self) -> None:
        with self._lock:
            self._items.clear()
            self._queue.clear()
            self._write(self._ms(), force=True, ended=True)

    def expected(self, by: str, item: str) -> int | None:
        recent = self.timings.get(f"{by}:{item}", [])[-5:]
        if recent:
            return round(statistics.median(recent))
        kind = item if item in MEDIA_TASKS else "text"
        return DEFAULT_SECONDS.get(("NotebookLM" if by == "NotebookLM" else "local", kind))

    # ---- what an item calls, through report() ----

    def _report(
        self,
        n: int,
        item: str,
        step: str | None,
        done: int | None,
        total: int | None,
        by: str | None,
        restart: bool,
        fraction: float | None = None,
    ) -> None:
        now = self._ms()
        with self._lock:
            entry = self._items.get((n, item))
            if entry is None:
                return
            new_step = step is not None and step != entry["step"]
            changed = new_step or restart or (by is not None and by != entry["by"])
            if by is not None:
                entry["by"] = by
            if restart:
                entry.update(
                    started=now,
                    expected=self.expected(entry["by"], item),
                    done=None,
                    total=None,
                    fraction=None,
                )
            if step is not None:
                entry["step"] = step
            if total is not None:
                entry.update(done=done, total=total)
            if fraction is not None:
                entry["fraction"] = round(min(1.0, max(0.0, fraction)), 4)
            entry["updated"] = now
            self._write(now, force=changed)

    # ---- writing ----

    def _ms(self) -> int:
        return int(self._clock() * 1000)

    def _write(self, now: int, force: bool = False, ended: bool = False) -> None:
        tick = time.monotonic()
        if not force and tick - self._last_write < WRITE_EVERY:
            return
        self._last_write = tick
        data = {
            "updated": now,
            "ended": ended,
            "pid": os.getpid(),
            "items": sorted(self._items.values(), key=lambda e: (e["n"], e["item"])),
            "queue": [{"n": n, "item": item} for n, item in self._queue],
        }
        try:
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(data), encoding="utf-8")
            os.replace(tmp, self.path)
        except OSError:  # the progress feed is a nicety: never fail an item over it
            pass


def report(
    step: str | None = None,
    *,
    done: int | None = None,
    total: int | None = None,
    by: str | None = None,
    restart: bool = False,
    fraction: float | None = None,
) -> None:
    """Say what the item being made is doing now (a no-op outside an item, e.g. in other commands)."""
    current = _current.get()
    if current is None:
        return
    feed, n, item = current
    with contextlib.suppress(Exception):  # the progress feed is a nicety: it must never break making an item
        feed._report(n, item, step, done, total, by, restart, fraction)
