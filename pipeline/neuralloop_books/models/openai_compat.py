"""OpenAI and OpenRouter through the OpenAI Chat Completions API (official `openai` SDK)."""

import openai

from . import QuotaError, SetupError

BASE_URLS = {"openai": None, "openrouter": "https://openrouter.ai/api/v1"}
NAMES = {"openai": "OpenAI", "openrouter": "OpenRouter"}


class OpenAICompatModel:
    def __init__(self, provider: str, model: str | None, api_key: str):
        self.provider, self.model, self.name = provider, model, NAMES[provider]
        self.base_url = BASE_URLS[provider]
        self.client = openai.AsyncOpenAI(api_key=api_key, base_url=self.base_url)

    async def check(self) -> None:
        if not self.model:
            raise SetupError(f"Choose a model for {self.name} in Settings.")
        try:
            await self.client.models.retrieve(self.model)
        except openai.AuthenticationError as error:
            raise SetupError(f"{self.name} didn't accept your key. Check it in Settings.") from error
        except openai.NotFoundError as error:
            raise SetupError(f"{self.name} doesn't have a model called {self.model}.") from error
        except openai.APIConnectionError as error:
            raise SetupError(f"Couldn't reach {self.name}. Check your internet connection.") from error

    async def complete(self, kind: str, system: str, source: str, prompt: str) -> str:
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": f"<chapter>\n{source}\n</chapter>\n\n{prompt}"},
        ]
        try:
            response = await self.client.chat.completions.create(
                model=self.model, messages=messages, response_format={"type": "json_object"}
            )
        except openai.RateLimitError as error:
            raise QuotaError(f"rate limit: {error}") from error
        except openai.BadRequestError:
            # Some OpenRouter models don't support JSON mode; our converters parse loose JSON anyway.
            response = await self.client.chat.completions.create(model=self.model, messages=messages)
        except (openai.AuthenticationError, openai.PermissionDeniedError, openai.NotFoundError) as error:
            raise SetupError(str(error)) from error
        return response.choices[0].message.content or ""
