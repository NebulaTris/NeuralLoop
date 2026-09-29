"""Any model Hermes Agent (Nous Research) is set up for, through its one-shot mode: `hermes -z PROMPT`.

Hermes is an agent with its own tools, and the chapter is part of the prompt. It runs in an empty folder, so
a book can't point it at the person's files by relative path; what its tools may do is Hermes's own setting.
"""

import asyncio
import re
import shutil
import tempfile

from . import QuotaError, SetupError, communicate

TIMEOUT = 1800.0
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")


class HermesModel:
    name = "Hermes Agent"
    provider = "hermes"

    def __init__(self, model: str | None, executable: str | None = None):
        if model and model.startswith("-"):
            raise SetupError(f"{model} isn't a model name Hermes Agent knows. Check it in Settings.")
        self.model = model
        self.executable = executable

    async def check(self) -> None:
        self.executable = self.executable or shutil.which("hermes")
        if not self.executable:
            raise SetupError(
                "Hermes Agent isn't installed. Install it from Nous Research, then run: hermes setup"
            )

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        await self.check()
        message = f"{system}\n\n<chapter>\n{source}\n</chapter>\n\n{prompt}"
        argv = [self.executable, "-z", message, *(["-m", self.model] if self.model else [])]
        with tempfile.TemporaryDirectory(prefix="neuralloop-hermes-") as empty:
            process = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, cwd=empty
            )
            stdout, stderr = await communicate(process, TIMEOUT)
        if process.returncode != 0:
            detail = _ANSI.sub("", stderr.decode(errors="replace")).strip()
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"Hermes Agent failed: {detail[:200]}")
        return stdout.decode(errors="replace").strip()
