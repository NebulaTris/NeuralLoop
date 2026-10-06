"""Any model Hermes Agent (Nous Research) is set up for, through its one-shot mode: `hermes -z PROMPT`.

Hermes is an agent with its own tools, its one-shot mode approves them automatically, and the chapter is part
of the prompt: a book could ask it to run commands or read files. Hermes has no switch to turn every tool off
for one run, so NeuralLoop won't use it unless the person opts in (ai.json `hermesTools: true`). Even then it
runs in an empty folder, with a minimal environment that holds none of our other providers' keys.
"""

import asyncio
import re
import shutil
import tempfile

from ..prompts import wrap_chapter
from . import QuotaError, SetupError, agent_env, communicate

TIMEOUT = 1800.0
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")
TOOLS_ON = (
    "Hermes Agent can't be used safely yet: it lets the model run tools, and a book's text could steer them. "
    "Choose another AI in Settings. If you trust every book you add, you can allow it anyway: "
    'turn on "Let Hermes use its tools" in Settings.'
)


class HermesModel:
    name = "Hermes Agent"
    provider = "hermes"

    def __init__(self, model: str | None, executable: str | None = None, allow_tools: bool = False):
        if model and model.startswith("-"):
            raise SetupError(f"{model} isn't a model name Hermes Agent knows. Check it in Settings.")
        self.model = model
        self.executable = executable
        self.allow_tools = allow_tools

    async def check(self) -> None:
        if not self.allow_tools:
            raise SetupError(TOOLS_ON)
        self.executable = self.executable or shutil.which("hermes")
        if not self.executable:
            raise SetupError(
                "Hermes Agent isn't installed. Install it from Nous Research, then run: hermes setup"
            )

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        await self.check()
        message = f"{system}\n\n{wrap_chapter(source)}\n\n{prompt}"
        argv = [self.executable, "-z", message, *(["-m", self.model] if self.model else [])]
        with tempfile.TemporaryDirectory(prefix="neuralloop-hermes-") as empty:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=empty,
                env=agent_env(("HERMES_",)),
            )
            stdout, stderr = await communicate(process, TIMEOUT)
        if process.returncode != 0:
            detail = _ANSI.sub("", stderr.decode(errors="replace")).strip()
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"Hermes Agent failed: {detail[:200]}")
        return stdout.decode(errors="replace").strip()
