"""OpenAI, OpenRouter, and any OpenAI-compatible service (Nous, Together, Groq, LM Studio, vLLM, …)
through the OpenAI Chat Completions API (official `openai` SDK)."""

import asyncio
import json
import re
import urllib.request
from urllib.parse import urlparse

import openai

from ..prompts import wrap_chapter
from ..schemas import SCHEMAS
from . import (
    QuotaError,
    SetupError,
    is_chat_model,
    is_local_url,
    normalize_base_url,
    output_cap_from_error,
    safe_message,
)

# A "thinking" model behind an OpenAI-compatible server can't be told to skip thinking; don't let one request
# hang for half an hour (the SDK's default is 10 minutes, retried twice).
REQUEST_TIMEOUT = 300.0
# A model on this Mac (LM Studio and friends) can be slow; as long as Ollama gets (models/ollama.py).
LOCAL_TIMEOUT = 900.0
MAX_OUTPUT_TOKENS = 8_192
# OpenAI's reasoning models count their thinking in this too, so it's roomier.
OPENAI_MAX_COMPLETION_TOKENS = 32_768
# Older OpenAI models allow less output than that; asking for more is a 400 on every item. Others are
# learned from the refusal (see `complete`).
_KNOWN_CAPS = (
    (re.compile(r"^(?:chat)?gpt-4o(?:-|$)"), 16_384),
    (re.compile(r"^gpt-4-(?:turbo|\d{4}-preview|1106|0125|vision)"), 4_096),
    (re.compile(r"^gpt-4(?:-\d{4}|-32k.*)?$"), 8_192),
    (re.compile(r"^gpt-3\.5-turbo"), 4_096),
)
_CHAT_TYPES = frozenset({"llm", "vlm", "chat"})
NATIVE_TIMEOUT = 3.0


def known_output_cap(model: str | None) -> int | None:
    name = (model or "").removeprefix("openai/")
    return next((cap for pattern, cap in _KNOWN_CAPS if pattern.match(name)), None)


def _lm_studio_models(base_url: str) -> dict[str, dict]:
    """What LM Studio's own API says about each model (`type`: llm, vlm, embeddings; `state`: loaded or
    not-loaded), which its OpenAI-compatible list leaves out. Empty when the server isn't LM Studio."""
    address = urlparse(base_url)
    try:
        with urllib.request.urlopen(
            f"{address.scheme}://{address.netloc}/api/v0/models", timeout=NATIVE_TIMEOUT
        ) as response:
            data = json.load(response).get("data", [])
    except (OSError, ValueError, AttributeError):  # not LM Studio, or an answer we can't read
        return {}
    if not isinstance(data, list):
        return {}
    return {m["id"]: m for m in data if isinstance(m, dict) and isinstance(m.get("id"), str)}


def pick_chat_model(models: list[dict]) -> str | None:
    """The model to use when none is named: one that writes text (never an embedding, reranking or speech
    model), preferring one the server says is loaded."""
    chat = [
        m
        for m in models
        if is_chat_model(m["id"]) and (not m.get("type") or str(m["type"]).lower() in _CHAT_TYPES)
    ]
    loaded = [m for m in chat if m.get("state") == "loaded" or m.get("loaded") is True]
    return (loaded or chat or [{"id": None}])[0]["id"]


# The official services' own addresses, always passed explicitly: an inherited OPENAI_BASE_URL must never
# redirect a saved key. Only `custom` uses an address the person gave.
BASE_URLS = {"openai": "https://api.openai.com/v1", "openrouter": "https://openrouter.ai/api/v1"}
NAMES = {"openai": "OpenAI", "openrouter": "OpenRouter"}
# OpenRouter's optional attribution header (shown on its activity page); never anything about the person.
HEADERS = {"openrouter": {"X-Title": "NeuralLoop"}}
LM_STUDIO_PORT = 1234


class OpenAICompatModel:
    def __init__(self, provider: str, model: str | None, api_key: str, base_url: str | None = None):
        self.provider, self.model = provider, model
        self.base_url = normalize_base_url(BASE_URLS.get(provider) or base_url)
        address = urlparse(self.base_url or "")
        if provider in NAMES:
            self.name = NAMES[provider]
        elif self.local and address.port == LM_STUDIO_PORT:
            self.name = "LM Studio"
        else:
            self.name = address.hostname or "your AI service"
        self._json_mode = True  # off once the service says it can't do it, so it isn't refused every time
        self._output_cap: int | None = None  # what the model said it allows, once it refused more
        self.client = openai.AsyncOpenAI(
            api_key=api_key,
            base_url=self.base_url,
            timeout=LOCAL_TIMEOUT if self.local else REQUEST_TIMEOUT,
            max_retries=1,
            default_headers=HEADERS.get(provider),
        )

    @property
    def local(self) -> bool:
        """A server on this Mac: only ever a `custom` address (OpenAI and OpenRouter are never local)."""
        return self.provider not in BASE_URLS and is_local_url(self.base_url)

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
            found = [{**(m.model_extra or {}), "id": m.id} async for m in self.client.models.list()]
        except openai.AuthenticationError as error:
            raise SetupError(f"{self.name} didn't accept your key. Check it in Settings.") from error
        except openai.APIConnectionError as error:
            raise SetupError(self._unreachable()) from error
        except openai.APIStatusError:
            found = None  # can't list here; the test request that follows checks the model
        if found is None:
            if not self.model:
                raise SetupError(f"Choose a model for {self.name} in Settings.")
            return
        listed = [m["id"] for m in found]
        if not listed:
            raise SetupError(f"{self.name} has no models yet. Load a model in it (in LM Studio: Developer).")
        if not self.model:
            if self.local:
                native = await asyncio.to_thread(_lm_studio_models, self.base_url)
                found = [{**m, **native.get(m["id"], {}), "id": m["id"]} for m in found]
            self.model = pick_chat_model(found)
            if not self.model:
                raise SetupError(
                    f"{self.name} has only embedding or speech models. Load a chat model in it "
                    "(in LM Studio: Developer)."
                )
        elif self.model not in listed:
            raise SetupError(
                f"{self.name} doesn't have a model called {self.model}. It has: {', '.join(listed[:5])}."
            )

    def _max_tokens(self) -> int:
        roomy = OPENAI_MAX_COMPLETION_TOKENS if self.provider == "openai" else MAX_OUTPUT_TOKENS
        return min(cap for cap in (roomy, known_output_cap(self.model), self._output_cap) if cap)

    def _request(self, kind: str, schema: dict | None, structured: bool) -> dict:
        tokens = (
            {"max_completion_tokens": self._max_tokens()}
            if self.provider == "openai"  # OpenAI's newer models refuse max_tokens
            else {"max_tokens": self._max_tokens()}
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

        async def send(structured: bool):
            return await self.client.chat.completions.create(
                model=self.model, messages=messages, **self._request(kind, schema, structured)
            )

        async def ask(structured: bool):
            try:
                return await send(structured)
            except openai.BadRequestError as error:
                # A model that allows less output than we asked for: once more within its limit, which is
                # kept for the rest of the run.
                cap = output_cap_from_error(error.message, self._max_tokens())
                if cap is None:
                    raise
                self._output_cap = cap
                return await send(structured)

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
