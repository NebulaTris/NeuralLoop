"""Claude through the Anthropic Messages API (official `anthropic` SDK)."""

import re

import anthropic

from ..prompts import wrap_chapter
from . import QuotaError, SetupError

MAX_TOKENS = 64_000  # streamed, so a long podcast script never hits an HTTP timeout
FALLBACK_BETA = "server-side-fallback-2026-07-01"
# Server-side fallbacks (when a safety check declines, another Claude answers) exist for these models only.
FALLBACK_MODELS = frozenset({"claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"})
_VERSION = re.compile(r"^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-|$)")


def adaptive_thinking(model: str) -> bool:
    """Claude 4.6 and later think adaptively; Haiku 4.5 and older models refuse it (a 400 on every item).
    A name we can't read is assumed to be a current model."""
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
        self.client = anthropic.AsyncAnthropic(api_key=api_key)

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
        try:
            async with self.client.beta.messages.stream(
                model=self.model,
                max_tokens=MAX_TOKENS,
                system=system,
                messages=[{"role": "user", "content": content}],
                **options,
            ) as stream:
                message = await stream.get_final_message()
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
