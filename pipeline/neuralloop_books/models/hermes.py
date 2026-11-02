"""Any model Hermes Agent (Nous Research) is set up for, one query at a time: `hermes chat -Q --query-file -`.

The prompt (book text) goes on stdin, never the command line: Windows' cmd.exe could read it, and a long
chapter goes over Windows' command-line limit. A Hermes without `--query-file` is asked to update first.

Hermes is an agent with its own tools, its one-shot mode approves them automatically, and the chapter is part
of the prompt: a book could ask it to run commands or read files. Hermes has no switch to turn every tool off
for one run, so NeuralLoop won't use it unless the person opts in (ai.json `hermesTools: true`). Even then it
runs in an empty folder, with a minimal environment that holds none of our other providers' keys.
"""

import asyncio
import re
import shutil
import tempfile
from pathlib import Path

from .. import portable
from ..prompts import wrap_chapter
from . import QuotaError, SetupError, agent_env, communicate

TIMEOUT = 1800.0
PROBE_TIMEOUT = 20.0
_query_file: dict[str, bool] = {}  # executable -> whether its `chat` has --query-file
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")
TOOLS_ON = (
    "Hermes Agent can't be used safely yet: it lets the model run tools, and a book's text could steer them. "
    "Choose another AI in Settings. If you trust every book you add, you can allow it anyway: "
    'turn on "Let Hermes use its tools" in Settings.'
)
UPDATE = "Update Hermes Agent so NeuralLoop can send it a chapter safely: hermes update"


def _env() -> dict[str, str]:
    """No keys of ours; Hermes is Python, so UTF-8 in and out whatever Windows' code page."""
    return {**agent_env(("HERMES_",)), "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}


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
        if portable.is_script_launcher(self.executable):
            raise SetupError(
                f"NeuralLoop can't run Hermes Agent through {Path(self.executable).name}: it needs "
                "hermes.exe. Install Hermes Agent so hermes.exe is on your PATH, then try again."
            )
        if not await self._reads_query_files():
            raise SetupError(UPDATE)

    async def _reads_query_files(self) -> bool:
        if self.executable not in _query_file:
            try:
                with tempfile.TemporaryDirectory(prefix="neuralloop-hermes-") as empty:
                    process = await asyncio.create_subprocess_exec(
                        self.executable,
                        "chat",
                        "--help",
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                        cwd=empty,
                        env=_env(),
                        **portable.no_window(),
                    )
                    stdout, stderr = await communicate(process, min(PROBE_TIMEOUT, TIMEOUT))
                _query_file[self.executable] = b"--query-file" in stdout + stderr
            except (OSError, asyncio.TimeoutError, TimeoutError):  # an old or odd Hermes: ask for an update
                _query_file[self.executable] = False
        return _query_file[self.executable]

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        await self.check()
        message = f"{system}\n\n{wrap_chapter(source)}\n\n{prompt}"
        # -Q: only the answer on stdout (the session id goes to stderr).
        argv = [
            self.executable,
            "chat",
            "-Q",
            "--query-file",
            "-",
            *(["-m", self.model] if self.model else []),
        ]
        with tempfile.TemporaryDirectory(prefix="neuralloop-hermes-") as empty:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=empty,
                env=_env(),
                **portable.no_window(),
            )
            stdout, stderr = await communicate(process, TIMEOUT, message.encode("utf-8"))
        if process.returncode != 0:
            detail = _ANSI.sub("", stderr.decode(errors="replace")).strip()
            if "no inference provider configured" in detail.lower():
                raise SetupError("Hermes Agent has no model yet. Choose one in Terminal: hermes model")
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"Hermes Agent failed: {detail[:200]}")
        return stdout.decode(errors="replace").strip()
