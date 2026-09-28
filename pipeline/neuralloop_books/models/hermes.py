"""Any model Hermes Agent (Nous Research) is set up for, through its one-shot mode: `hermes -z PROMPT`."""

import asyncio
import shutil

from . import QuotaError, SetupError

TIMEOUT = 1800.0
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")


class HermesModel:
    name = "Hermes Agent"
    provider = "hermes"

    def __init__(self, model: str | None, executable: str | None = None):
        self.model = model
        self.executable = executable

    async def check(self) -> None:
        self.executable = self.executable or shutil.which("hermes")
        if not self.executable:
            raise SetupError(
                "Hermes Agent isn't installed. Install it from Nous Research, then run: hermes setup"
            )

    async def complete(self, kind: str, system: str, source: str, prompt: str) -> str:
        await self.check()
        message = f"{system}\n\n<chapter>\n{source}\n</chapter>\n\n{prompt}"
        argv = [self.executable, "-z", message, *(["-m", self.model] if self.model else [])]
        process = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), TIMEOUT)
        if process.returncode != 0:
            detail = stderr.decode(errors="replace").strip()
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"Hermes Agent failed: {detail[:200]}")
        return stdout.decode(errors="replace").strip()
