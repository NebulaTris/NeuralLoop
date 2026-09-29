"""Any model opencode is set up for (for example DeepSeek), through `opencode run` without its TUI.

opencode is a coding agent: left to its defaults, `opencode run` lets the model run shell commands and edit
files. The chapter is part of the prompt, so a book could ask the model to do exactly that. NeuralLoop only
needs text back, so every tool is denied (the model isn't even offered one), the person's project config is
ignored, and it runs in an empty folder. opencode 2 serves every `run` from one background service with the
person's own settings; where `--standalone` exists, a private server is used instead so these rules apply.
"""

import asyncio
import json
import os
import re
import shutil
import tempfile

from . import QuotaError, SetupError, communicate

TIMEOUT = 1800.0
PROBE_TIMEOUT = 20.0
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")
NO_TOOLS = json.dumps({"permission": {"*": "deny"}})
_standalone: dict[str, bool] = {}  # executable -> whether its `run` has --standalone


def locked_down_env() -> dict[str, str]:
    return {**os.environ, "OPENCODE_CONFIG_CONTENT": NO_TOOLS, "OPENCODE_DISABLE_PROJECT_CONFIG": "1"}


class OpencodeModel:
    name = "opencode"
    provider = "opencode"

    def __init__(self, model: str | None, executable: str | None = None):
        if model and model.startswith("-"):
            raise SetupError(f"{model} isn't a model name opencode knows. Check it in Settings.")
        self.model = model
        self.executable = executable

    async def check(self) -> None:
        self.executable = self.executable or shutil.which("opencode")
        if not self.executable:
            raise SetupError("opencode isn't installed. Install it from https://opencode.ai, then run again.")

    async def _has_standalone(self) -> bool:
        if self.executable not in _standalone:
            try:
                process = await asyncio.create_subprocess_exec(
                    self.executable,
                    "run",
                    "--help",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, stderr = await communicate(process, min(PROBE_TIMEOUT, TIMEOUT))
                _standalone[self.executable] = b"--standalone" in stdout + stderr
            except (OSError, asyncio.TimeoutError, TimeoutError):  # an old or odd opencode: run it plainly
                _standalone[self.executable] = False
        return _standalone[self.executable]

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        await self.check()
        message = f"{system}\n\n<chapter>\n{source}\n</chapter>\n\n{prompt}"
        standalone = ["--standalone"] if await self._has_standalone() else []
        argv = [self.executable, "run", *standalone, *(["-m", self.model] if self.model else []), message]
        with tempfile.TemporaryDirectory(prefix="neuralloop-opencode-") as empty:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=empty,
                env=locked_down_env(),
            )
            stdout, stderr = await communicate(process, TIMEOUT)
        if process.returncode != 0:
            detail = _ANSI.sub("", stderr.decode(errors="replace")).strip()
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"opencode failed: {detail[:200]}")
        return _ANSI.sub("", stdout.decode(errors="replace")).strip()
