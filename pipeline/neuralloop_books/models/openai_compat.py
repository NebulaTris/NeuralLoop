"""OpenAI, OpenRouter, and any OpenAI-compatible service (Nous, Together, Groq, LM Studio, vLLM, …)
through the OpenAI Chat Completions API (official `openai` SDK)."""

from urllib.parse import urlparse

import openai

from ..prompts import wrap_chapter
from ..schemas import SCHEMAS
from . import QuotaError, SetupError, is_local_url, normalize_base_url, safe_message

# A "thinking" model behind an OpenAI-compatible server can't be told to skip thinking; don't let one request
# hang for half an hour (the SDK's default is 10 minutes, retried twice).
REQUEST_TIMEOUT = 300.0
# A model on this Mac (LM Studio and friends) can be slow; as long as Ollama gets (models/ollama.py).
LOCAL_TIMEOUT = 900.0
MAX_OUTPUT_TOKENS = 8_192
# OpenAI's reasoning models count their thinking in this too, so it's roomier.
OPENAI_MAX_COMPLETION_TOKENS = 32_768

BASE_URLS = {"openai": None, "openrouter": "https://openrouter.ai/api/v1"}
NAMES = {"openai": "OpenAI", "openrouter": "OpenRouter"}
# OpenRouter's optional attribution header (shown on its activity page); never anything about the person.
HEADERS = {"openrouter": {"X-Title": "NeuralLoop"}}
LM_STUDIO_PORT = 1234


class OpenAICompatModel:
    def __init__(self, provider: str, model: str | None, api_key: str, base_url: str | None = None):
        self.provider, self.model = provider, model
        self.base_url = normalize_base_url(base_url or BASE_URLS.get(provider))
        address = urlparse(self.base_url or "")
        if provider in NAMES:
            self.name = NAMES[provider]
        elif self.local and address.port == LM_STUDIO_PORT:
            self.name = "LM Studio"
        else:
            self.name = address.hostname or "your AI service"
        self._json_mode = True  # off once the service says it can't do it, so it isn't refused every time
        self.client = openai.AsyncOpenAI(
            api_key=api_key,
            base_url=self.base_url,
            timeout=LOCAL_TIMEOUT if self.local else REQUEST_TIMEOUT,
            max_retries=1,
            default_headers=HEADERS.get(provider),
        )

    @property
    def local(self) -> bool:
        return is_local_url(self.base_url)

    def _unreachable(self) -> str:
        if self.local:
            return f"Nothing is answering at {self.base_url}. Start its server (in LM Studio: Developer)."
        return f"Couldn't reach {self.name}. Check your internet connection."

    async def check(self) -> None:
        if self.provider == "custom":
            return await self._check_listed()
        if not self.model:
            raise SetupError(f"Choose a model for {self.name} in Settings.")
        if self.provider == "openrouter":
            return  # no single-model lookup there; the test request that follows checks the key and model
        try:
            await self.client.models.retrieve(self.model)
        except openai.AuthenticationError as error:
            raise SetupError(f"{self.name} didn't accept your key. Check it in Settings.") from error
        except openai.NotFoundError as error:
            raise SetupError(f"{self.name} doesn't have a model called {self.model}.") from error
        except openai.APIConnectionError as error:
            raise SetupError(self._unreachable()) from error

    async def _check_listed(self) -> None:
        """Compatible servers (LM Studio, vLLM, …) often have no single-model lookup, but they all list their
        models: check the named one is there, or use the first (LM Studio's loaded one) when none is named."""
        try:
            listed = [m.id async for m in self.client.models.list()]
        except openai.AuthenticationError as error:
            raise SetupError(f"{self.name} didn't accept your key. Check it in Settings.") from error
        except openai.APIConnectionError as error:
            raise SetupError(self._unreachable()) from error
        except openai.APIStatusError:
            listed = None  # can't list here; the test request that follows checks the model
        if listed is None:
            if not self.model:
                raise SetupError(f"Choose a model for {self.name} in Settings.")
            return
        if not listed:
            raise SetupError(f"{self.name} has no models yet. Load a model in it (in LM Studio: Developer).")
        if not self.model:
            self.model = listed[0]
        elif self.model not in listed:
            raise SetupError(
                f"{self.name} doesn't have a model called {self.model}. It has: {', '.join(listed[:5])}."
            )

    def _request(self, kind: str, schema: dict | None, structured: bool) -> dict:
        tokens = (
            {"max_completion_tokens": OPENAI_MAX_COMPLETION_TOKENS}
            if self.provider == "openai"  # OpenAI's newer models refuse max_tokens
            else {"max_tokens": MAX_OUTPUT_TOKENS}
        )
        if not structured:
            return tokens
        if self.local:
            # LM Studio refuses JSON mode but takes a schema, which also keeps small models to the shape.
            shape = schema or SCHEMAS.get(kind) or {"type": "object"}
            return {
                **tokens,
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {"name": "answer", "schema": shape},
                },
            }
        return {**tokens, "response_format": {"type": "json_object"}}

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        if not self.model:
            await self.check()  # e.g. grading recall with LM Studio's loaded model; check() wasn't called
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": f"{wrap_chapter(source)}\n\n{prompt}"},
        ]

        async def ask(structured: bool):
            return await self.client.chat.completions.create(
                model=self.model, messages=messages, **self._request(kind, schema, structured)
            )

        try:
            try:
                response = await ask(self._json_mode)
            except openai.BadRequestError:
                if not self._json_mode:
                    raise
                # Some models and servers don't do JSON mode; our converters parse loose JSON anyway.
                response = await ask(False)
                self._json_mode = False
        except openai.RateLimitError as error:
            raise QuotaError(f"rate limit: {error}") from error
        except openai.AuthenticationError as error:
            raise SetupError(f"{self.name} didn't accept your key. Check it in Settings.") from error
        except openai.NotFoundError as error:
            raise SetupError(f"{self.name} doesn't have a model called {self.model}.") from error
        except openai.PermissionDeniedError as error:
            raise SetupError(f"{self.name} says your key can't use {self.model}.") from error
        except openai.APITimeoutError as error:
            # A slow answer (or a dropped connection) fails this one item, which can be tried again;
            # only check() stops a run over the connection.
            raise RuntimeError(f"{self.name} took too long to answer") from error
        except openai.APIConnectionError as error:
            raise RuntimeError(self._unreachable()) from error
        except openai.APIStatusError as error:
            if error.status_code == 402:  # OpenRouter: out of credit
                raise QuotaError(f"{self.name} is out of credit: {safe_message(error.message)}") from error
            raise RuntimeError(f"{self.name} couldn't answer: {safe_message(error.message)}") from error
        return response.choices[0].message.content or ""
