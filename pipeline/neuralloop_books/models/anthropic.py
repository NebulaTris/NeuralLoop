"""Claude through the Anthropic Messages API (official `anthropic` SDK)."""

import re

import anthropic

from ..prompts import wrap_chapter
from . import QuotaError, SetupError, output_cap_from_error

BASE_URL = "https://api.anthropic.com"
MAX_TOKENS = 64_000  # streamed, so a long podcast script never hits an HTTP timeout
# Older models allow less output; asking for more is a 400 on every item.
_OLDER_CAPS = (
    (re.compile(r"^claude-opus-4(?:-[01])?(?:-\d{8})?$"), 32_000),
    (re.compile(r"^claude-3-5-"), 8_192),
    (re.compile(r"^claude-3-(?:opus|sonnet|haiku)"), 4_096),
    (re.compile(r"^claude-(?:2|instant)"), 4_096),
)
FALLBACK_BETA = "server-side-fallback-2026-07-01"
# Server-side fallbacks (when a safety check declines, another Claude answers) exist for these models only.
FALLBACK_MODELS = frozenset({"claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"})
_VERSION = re.compile(r"^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-|$)")
# Claude 3 and older put the version first (claude-3-7-sonnet-latest, claude-2.1, claude-instant-1.2).
_LEGACY = re.compile(r"^claude-(?:\d|instant)")


def max_output_tokens(model: str) -> int:
    """The most output to ask this model for."""
    return next((cap for pattern, cap in _OLDER_CAPS if pattern.match(model)), MAX_TOKENS)


def adaptive_thinking(model: str) -> bool:
    """Claude 4.6 and later think adaptively; Haiku 4.5 and older models refuse it (a 400 on every item).
    A name we can't read is assumed to be a current model."""
    if _LEGACY.match(model):
        return False
    match = _VERSION.match(model)
    if not match:
        return True
    family, version = match.group(1), (int(match.group(2)), int(match.group(3) or 0))
    if family == "haiku":
        return version >= (5, 0)
    return version >= (4, 6)


class AnthropicModel:
    name = "Claude"
    provider = "anthropic"

    def __init__(self, model: str, api_key: str):
        self.model = model
        self.max_tokens = max_output_tokens(model)  # lowered for the run if the model says it allows less
        # Always Anthropic's own address: an inherited ANTHROPIC_BASE_URL must never redirect the saved key.
        self.client = anthropic.AsyncAnthropic(api_key=api_key, base_url=BASE_URL)

    async def check(self) -> None:
        try:
            await self.client.models.retrieve(self.model)
        except anthropic.AuthenticationError as error:
            raise SetupError("Anthropic didn't accept your key. Check it in Settings.") from error
        except anthropic.NotFoundError as error:
            raise SetupError(f"Anthropic doesn't have a model called {self.model}.") from error
        except anthropic.APIConnectionError as error:
            raise SetupError("Couldn't reach Anthropic. Check your internet connection.") from error

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        content = [
            # The chapter comes first and is cached, so a chapter's other items reuse it.
            {
                "type": "text",
                "text": wrap_chapter(source),
                "cache_control": {"type": "ephemeral"},
            },
            {"type": "text", "text": prompt},
        ]
        options: dict = {}
        if adaptive_thinking(self.model):
            options["thinking"] = {"type": "adaptive"}
        if self.model in FALLBACK_MODELS:
            options.update(betas=[FALLBACK_BETA], fallbacks="default")

        async def ask() -> anthropic.types.beta.BetaMessage:
            async with self.client.beta.messages.stream(
                model=self.model,
                max_tokens=self.max_tokens,
                system=system,
                messages=[{"role": "user", "content": content}],
                **options,
            ) as stream:
                return await stream.get_final_message()

        try:
            try:
                message = await ask()
            except anthropic.BadRequestError as error:
                # A model that allows less output than we asked for: ask once more within its limit.
                cap = output_cap_from_error(error.message, self.max_tokens)
                if cap is None:
                    raise
                self.max_tokens = cap
                message = await ask()
        except anthropic.RateLimitError as error:
            raise QuotaError(f"rate limit: {error}") from error
        except (
            anthropic.AuthenticationError,
            anthropic.PermissionDeniedError,
            anthropic.NotFoundError,
        ) as error:
            raise SetupError(str(error)) from error
        if message.stop_reason == "refusal":
            raise ValueError("Claude declined to write this item")
        return "".join(block.text for block in message.content if block.type == "text")
