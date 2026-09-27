"""Any model opencode is set up for (for example DeepSeek), through `opencode run` without its TUI."""

import asyncio
import re
import shutil

from . import QuotaError, SetupError

TIMEOUT = 1800.0
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")


class OpencodeModel:
    name = "opencode"
    provider = "opencode"

    def __init__(self, model: str | None, executable: str | None = None):
        self.model = model
        self.executable = executable

    async def check(self) -> None:
        self.executable = self.executable or shutil.which("opencode")
        if not self.executable:
            raise SetupError("opencode isn't installed. Install it from https://opencode.ai, then run again.")

    async def complete(self, kind: str, system: str, source: str, prompt: str) -> str:
        await self.check()
        message = f"{system}\n\n<chapter>\n{source}\n</chapter>\n\n{prompt}"
        argv = [self.executable, "run", *(["-m", self.model] if self.model else []), message]
        process = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), TIMEOUT)
        if process.returncode != 0:
            detail = stderr.decode(errors="replace").strip()
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"opencode failed: {detail[:200]}")
        return _ANSI.sub("", stdout.decode(errors="replace")).strip()
