"""Text models the local engine can use. Each has `name`, `model`, `check()` and `complete()`.

`complete(kind, system, source, prompt)` sends the chapter (`source`) before the task prompt, so providers
that cache prompt prefixes reuse it across a chapter's items. `kind` ("quiz", "audio", …) is only for logs
and the fake model.
"""

import os
from collections.abc import Mapping
from typing import Protocol

from ..config import DEFAULT_MODELS, PROVIDER_KEYS


class SetupError(Exception):
    """Something to fix before any work can start (missing key, model not found, Ollama not running)."""


class QuotaError(Exception):
    """The provider's rate limit or credit was reached; the item waits for the next run."""


class TextModel(Protocol):
    name: str
    model: str | None

    async def check(self) -> None: ...

    async def complete(self, kind: str, system: str, source: str, prompt: str) -> str: ...


def resolve_provider(provider: str, env: Mapping[str, str]) -> str:
    """`auto` picks the first provider with a key set, or local Ollama when there are none."""
    if provider != "auto":
        return provider
    return next((name for name, variable in PROVIDER_KEYS.items() if env.get(variable)), "ollama")


def make_model(provider: str, model: str | None, env: Mapping[str, str] | None = None) -> TextModel:
    env = os.environ if env is None else env
    provider = resolve_provider(provider, env)
    model = model or DEFAULT_MODELS.get(provider)
    if provider in PROVIDER_KEYS:
        key = env.get(PROVIDER_KEYS[provider], "")
        if not key:
            raise SetupError(
                f"No key for {provider}. Add yours in NeuralLoop's Settings, "
                f"or set {PROVIDER_KEYS[provider]}."
            )
        if provider == "anthropic":
            from .anthropic import AnthropicModel

            return AnthropicModel(model, api_key=key)
        from .openai_compat import OpenAICompatModel

        return OpenAICompatModel(provider, model, api_key=key)
    if provider == "ollama":
        from .ollama import OllamaModel

        return OllamaModel(model, host=env.get("OLLAMA_HOST", ""))
    if provider == "opencode":
        from .opencode import OpencodeModel

        return OpencodeModel(model)
    if provider == "fake":
        from .fake import FakeModel

        return FakeModel()
    raise SetupError(f"Unknown AI provider: {provider}")
