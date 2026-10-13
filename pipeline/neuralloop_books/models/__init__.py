"""Text models the local engine can use. Each has `name`, `model`, `check()` and `complete()`.

`complete(kind, system, source, prompt)` sends the chapter (`source`) before the task prompt, so providers
that cache prompt prefixes reuse it across a chapter's items. `kind` ("quiz", "audio", …) is only for logs
and the fake model.
`schema` optionally pins the exact JSON shape for this one request (only Ollama uses it).
"""

import asyncio
import contextlib
import os
import re
from collections.abc import Mapping
from typing import Protocol
from urllib.parse import urlparse

from ..config import DEFAULT_MODELS, PROVIDER_KEYS

# Listed models that can't write text (embedding, reranking, speech, image): never picked as the one to use.
_NOT_CHAT = re.compile(
    r"embed|rerank|whisper|tts|transcribe|moderation|dall-e|\bbge\b|minilm|\bgte-|^paraphrase-", re.IGNORECASE
)


def is_chat_model(name: str) -> bool:
    """Whether a listed model's name looks like one that writes text (`nomic-embed-text` doesn't)."""
    return not _NOT_CHAT.search(name)


class SetupError(Exception):
    """Something to fix before any work can start (missing key, model not found, Ollama not running)."""


class QuotaError(Exception):
    """The provider's rate limit or credit was reached; the item waits for the next run."""


class TextModel(Protocol):
    name: str
    model: str | None

    async def check(self) -> None: ...

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str: ...


async def communicate(process: asyncio.subprocess.Process, timeout: float) -> tuple[bytes, bytes]:
    """(stdout, stderr) of a model's command line; on a timeout or a cancelled run, the child stops too."""
    try:
        return await asyncio.wait_for(process.communicate(), timeout)
    except (asyncio.TimeoutError, TimeoutError, asyncio.CancelledError):
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        raise


KEY_VARIABLES = (*PROVIDER_KEYS.values(), "NEURALLOOP_API_KEY")
# Key-shaped tokens (Anthropic, OpenAI, OpenRouter, bearer headers), for keys not from our variables.
_KEY_SHAPES = re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}|\b[Bb]earer\s+[A-Za-z0-9._~+/\-]{16,}=*")


def safe_message(text: object, limit: int = 200, env: Mapping[str, str] | None = None) -> str:
    """One line of error text that is safe to print and save. SDK and command-line errors can quote the
    request, and progress lines and the book's files (which can sync to Drive) must never hold a key.
    Multi-line text is joined, so it can't pose as one of the pipeline's own progress lines."""
    env = os.environ if env is None else env
    line = " ".join(str(text).split())
    for variable in KEY_VARIABLES:
        key = env.get(variable, "")
        if len(key) >= 8:
            line = line.replace(key, "[key hidden]")
    return _KEY_SHAPES.sub("[key hidden]", line)[:limit]


_TOKEN_PARAMETER = re.compile(r"max_(?:completion_|output_)?tokens", re.IGNORECASE)
_STATED_CAP = (
    re.compile(r"at most `?(\d+)`? (?:completion |output )?tokens", re.IGNORECASE),  # OpenAI
    re.compile(r"> ?(\d+), which is the maximum", re.IGNORECASE),  # Anthropic
    re.compile(
        r"(?:less than or equal to|<=|at most|maximum (?:value |allowed )?is) ?`?(\d+)", re.IGNORECASE
    ),
)
_TOO_LARGE = re.compile(r"too large|too many|exceed|maximum|greater than|must be less", re.IGNORECASE)
MIN_OUTPUT_CAP = 1_024


def output_cap_from_error(message: str, asked: int) -> int | None:
    """When a service refuses a request because it asked for more output tokens than the model allows, the
    limit to ask for instead: the one the message states, or half of what was asked when it states none.
    None when the refusal is about something else (an input too long for the model is not fixed by this)."""
    text = str(message)
    if not _TOKEN_PARAMETER.search(text) or not _TOO_LARGE.search(text):
        return None
    for pattern in _STATED_CAP:
        match = pattern.search(text)
        if match and 0 < int(match.group(1)) < asked:
            return int(match.group(1))
    return asked // 2 if asked // 2 >= MIN_OUTPUT_CAP else None


# What an agent's command line (opencode, Hermes) needs from our environment to start and reach its own
# service; everything else, above all the keys for our other providers, stays with us.
_AGENT_ENV = (
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "TERM",
    "LANG",
    "TZ",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
)


def agent_env(own_prefixes: tuple[str, ...] = (), env: Mapping[str, str] | None = None) -> dict[str, str]:
    """A minimal environment for an agent's command line: the basics, locale and XDG folders, plus
    variables starting with `own_prefixes` (the agent's own settings). Never our providers' keys."""
    env = os.environ if env is None else env
    keep = {
        name: value
        for name, value in env.items()
        if name in _AGENT_ENV or name.startswith(("LC_", "XDG_", *own_prefixes))
    }
    for variable in KEY_VARIABLES:
        keep.pop(variable, None)
    return keep


def normalize_base_url(url: str | None) -> str | None:
    """An OpenAI-compatible address as people type it into Settings, as the SDK needs it: with a scheme, and
    with /v1 when no path was given (LM Studio, vLLM, Together, … all serve the API under /v1)."""
    if not url:
        return url
    url = url.strip()
    if "://" not in url:
        url = f"http://{url}"
    if urlparse(url).path in ("", "/"):
        url = f"{url.rstrip('/')}/v1"
    return url


def is_local_url(url: str | None) -> bool:
    """Whether an OpenAI-compatible address is a server on this Mac (LM Studio and friends)."""
    return bool(url) and urlparse(normalize_base_url(url)).hostname in (
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "::1",
    )


def resolve_provider(provider: str, env: Mapping[str, str]) -> str:
    """`auto` picks the first provider with a key set, or local Ollama when there are none."""
    if provider != "auto":
        return provider
    return next((name for name, variable in PROVIDER_KEYS.items() if env.get(variable)), "ollama")


def make_model(
    provider: str,
    model: str | None,
    env: Mapping[str, str] | None = None,
    *,
    allow_agent_tools: bool = False,
) -> TextModel:
    """`allow_agent_tools`: the person's explicit opt-in (ai.json `hermesTools`) to run Hermes Agent even
    though its tools can't be turned off."""
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
    if provider == "custom":
        base_url = env.get("NEURALLOOP_BASE_URL", "")
        if not base_url:
            raise SetupError("Add the address of your AI service in Settings, or set NEURALLOOP_BASE_URL.")
        from .openai_compat import OpenAICompatModel

        return OpenAICompatModel(
            "custom", model, api_key=env.get("NEURALLOOP_API_KEY") or "none", base_url=base_url
        )
    if provider == "hermes":
        from .hermes import HermesModel

        return HermesModel(model, allow_tools=allow_agent_tools)
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
