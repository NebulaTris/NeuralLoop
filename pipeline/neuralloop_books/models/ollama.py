"""Local models through Ollama's native chat API (standard library only).

The native API is used because it lets us raise the context window (`num_ctx`); Ollama's default is small
enough to silently cut chapters off.
"""

import asyncio
import json
import urllib.error
import urllib.request

from ..schemas import SCHEMAS
from . import QuotaError, SetupError

DEFAULT_HOST = "http://localhost:11434"
CONTEXT_TOKENS = 16_384
# Small models in JSON mode can loop until the context is full; a long podcast script fits well within this.
MAX_OUTPUT_TOKENS = 8_192
TIMEOUT = 900.0  # local models on a laptop can be slow


def _get_json(url: str, timeout: float) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def _post_json(url: str, body: dict, timeout: float) -> dict:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


class OllamaModel:
    name = "Ollama"
    provider = "ollama"

    def __init__(self, model: str | None, host: str = ""):
        self.model = model
        self.base_url = (host or DEFAULT_HOST).rstrip("/")

    async def check(self) -> None:
        try:
            tags = await asyncio.to_thread(_get_json, f"{self.base_url}/api/tags", 5.0)
        except OSError as error:
            raise SetupError("Ollama isn't running. Open the Ollama app, or run: ollama serve") from error
        installed = [m["name"] for m in tags.get("models", [])]
        if not installed:
            raise SetupError(
                "Ollama has no models yet. Download one first, for example: ollama pull gpt-oss:20b"
            )
        if not self.model:
            self.model = installed[0]
        elif self.model not in installed and f"{self.model}:latest" not in installed:
            raise SetupError(f"Ollama doesn't have {self.model} yet. Run: ollama pull {self.model}")

    async def complete(self, kind: str, system: str, source: str, prompt: str) -> str:
        body = {
            "model": self.model,
            "stream": False,
            "format": SCHEMAS.get(kind, "json"),
            "options": {"num_ctx": CONTEXT_TOKENS, "num_predict": MAX_OUTPUT_TOKENS},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": f"<chapter>\n{source}\n</chapter>\n\n{prompt}"},
            ],
        }
        try:
            answer = await asyncio.to_thread(_post_json, f"{self.base_url}/api/chat", body, TIMEOUT)
        except urllib.error.HTTPError as error:
            if error.code == 429:
                raise QuotaError("Ollama is busy") from error
            raise
        except urllib.error.URLError as error:
            raise SetupError("Ollama stopped running. Open the Ollama app, then run again.") from error
        return answer.get("message", {}).get("content", "")
