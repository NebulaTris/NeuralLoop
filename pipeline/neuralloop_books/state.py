"""The saved progress of one book (state.json), so every run can resume where the last one stopped."""

import json
import os
from pathlib import Path

from .config import MEDIA_TASKS, TASKS

TODO, WORKING, DONE, SKIPPED, WAITING, FAILED = (
    "todo",
    "working",
    "done",
    "skipped",
    "waiting_quota",
    "failed",
)


class UnreadableState(ValueError):
    """state.json is there but isn't a book's state (cut short, or not JSON)."""


class BookState:
    def __init__(self, path: Path, data: dict):
        self.path = path
        self.data = data

    @classmethod
    def load(cls, path: Path) -> "BookState | None":
        """The saved state, None when there's none yet; UnreadableState when the file can't be used."""
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise UnreadableState(f"state.json isn't valid JSON ({error})") from error
        if not isinstance(data, dict) or not isinstance(data.get("chapters"), list):
            raise UnreadableState("state.json doesn't hold a book's chapters")
        return cls(path, data)

    @classmethod
    def create(
        cls, path: Path, *, title: str, source: str, chapters: list[dict], dry_run: bool
    ) -> "BookState":
        records = [{**c, "sourceId": None, "tasks": {t: {"status": TODO} for t in TASKS}} for c in chapters]
        state = cls(
            path,
            {"title": title, "source": source, "dryRun": dry_run, "notebookId": None, "chapters": records},
        )
        state.save()
        return state

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(self.data, indent=1, ensure_ascii=False))
            handle.flush()
            os.fsync(handle.fileno())  # on disk before it's swapped in: a power cut never leaves half a file
        os.replace(tmp, self.path)

    @property
    def chapters(self) -> list[dict]:
        return self.data["chapters"]

    def ensure_tasks(self) -> None:
        """Books started with an older version gain any tasks added since."""
        for chapter in self.chapters:
            for task in TASKS:
                chapter["tasks"].setdefault(task, {"status": TODO})

    def apply_selection(
        self, chapters: set[int], media: set[int], *, audio: bool, video: bool, retry: bool
    ) -> None:
        """Mark what this run should make. Finished work is never redone.

        Items that waited for a limit are tried again on every run (the limit may have reset); failed items
        only with `retry`, so one that keeps failing doesn't slow every run down.
        """
        wanted_media = {"audio": audio, "video": video}
        for chapter in self.chapters:
            for task, entry in chapter["tasks"].items():
                if entry["status"] == WAITING or (retry and entry["status"] == FAILED):
                    entry["status"] = TODO
                excluded = chapter["n"] not in chapters or (
                    task in MEDIA_TASKS and (chapter["n"] not in media or not wanted_media[task])
                )
                if excluded and entry["status"] == TODO:
                    entry["status"] = SKIPPED
                elif not excluded and entry["status"] == SKIPPED:
                    entry["status"] = TODO

    def reset_interrupted(self) -> int:
        """Items a crashed or quit run left "working" go back to the queue. Returns how many."""
        count = 0
        for chapter in self.chapters:
            for entry in chapter["tasks"].values():
                if entry["status"] == WORKING:
                    entry["status"] = TODO
                    count += 1
        return count

    def pending(self) -> list[tuple[dict, str]]:
        """(chapter, task) pairs still to make, in reading order: chapter 1 is finished first, then 2, …"""
        return [(c, t) for c in self.chapters for t in TASKS if c["tasks"][t]["status"] == TODO]

    def counts(self) -> dict[str, int]:
        totals: dict[str, int] = {}
        for chapter in self.chapters:
            for entry in chapter["tasks"].values():
                totals[entry["status"]] = totals.get(entry["status"], 0) + 1
        return totals
