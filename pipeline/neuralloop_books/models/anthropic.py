"""Claude through the Anthropic Messages API (official `anthropic` SDK)."""

import anthropic

from . import QuotaError, SetupError

MAX_TOKENS = 64_000  # streamed, so a long podcast script never hits an HTTP timeout
FALLBACK_BETA = "server-side-fallback-2026-07-01"


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
                "text": f"<chapter>\n{source}\n</chapter>",
                "cache_control": {"type": "ephemeral"},
            },
            {"type": "text", "text": prompt},
        ]
        try:
            async with self.client.beta.messages.stream(
                model=self.model,
                max_tokens=MAX_TOKENS,
                system=system,
                messages=[{"role": "user", "content": content}],
                thinking={"type": "adaptive"},
                betas=[FALLBACK_BETA],
                fallbacks="default",
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
