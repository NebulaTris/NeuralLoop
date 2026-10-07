"""Local models through Ollama's native chat API (standard library only).

The native API is used because it lets us raise the context window (`num_ctx`); Ollama's default is small
enough to silently cut chapters off.
"""

import asyncio
import json
import urllib.error
import urllib.request

from ..prompts import wrap_chapter
from ..schemas import SCHEMAS
from ..setup import local_model_for_memory, ollama_host, total_memory
from . import QuotaError, SetupError

CONTEXT_TOKENS = 16_384
# Small models in JSON mode can loop until the context is full; a long podcast script fits well within this.
MAX_OUTPUT_TOKENS = 8_192
TIMEOUT = 900.0  # local models on a laptop can be slow
KEEP_ALIVE = "30m"  # stay loaded between a book's items instead of reloading each time


def _get_json(url: str, timeout: float) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def _post_json(url: str, body: dict, timeout: float) -> dict:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def default_local_model() -> str:
    return local_model_for_memory(total_memory())


class OllamaModel:
    name = "Ollama"
    provider = "ollama"

    def __init__(self, model: str | None, host: str = ""):
        self.model = model
        if host and not host.startswith("http"):
            host = f"http://{host}"
        self.base_url = (host or ollama_host()).rstrip("/")

    async def check(self) -> None:
        try:
            tags = await asyncio.to_thread(_get_json, f"{self.base_url}/api/tags", 5.0)
        except OSError as error:
            raise SetupError(
                "Your Mac's AI (Ollama) isn't running. Quit and reopen NeuralLoop to start it, "
                "or open the Ollama app if you installed it yourself."
            ) from error
        installed = [m["name"] for m in tags.get("models", [])]
        if not installed:
            raise SetupError(
                "Your Mac's AI has no model yet. NeuralLoop downloads one the next time it prepares a "
                "book; check your internet connection, or pick a model in Settings → Your AI."
            )
        if not self.model:
            preferred = default_local_model()
            self.model = preferred if preferred in installed else installed[0]
        elif self.model not in installed and f"{self.model}:latest" not in installed:
            raise SetupError(
                f"Your Mac's AI doesn't have {self.model} yet. NeuralLoop downloads it the next time "
                "it prepares a book; check your internet connection, or pick another model in "
                "Settings → Your AI."
            )

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        if not self.model:
            await self.check()  # e.g. grading recall: picks the installed model, as a book run does
        body = {
            "model": self.model,
            "stream": False,
            "think": False,  # "thinking" models are slower and don't write better JSON for this
            "keep_alive": KEEP_ALIVE,
            "format": schema or SCHEMAS.get(kind, "json"),
            "options": {"num_ctx": CONTEXT_TOKENS, "num_predict": MAX_OUTPUT_TOKENS},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": f"{wrap_chapter(source)}\n\n{prompt}"},
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
