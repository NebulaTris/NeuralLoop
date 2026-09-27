import asyncio
from types import SimpleNamespace

import pytest

from neuralloop_books import models
from neuralloop_books.models import QuotaError, SetupError
from neuralloop_books.models.opencode import OpencodeModel
from neuralloop_books.notebook import is_quota_error


def test_auto_picks_the_first_provider_with_a_key():
    assert models.resolve_provider("auto", {"OPENROUTER_API_KEY": "k"}) == "openrouter"
    assert models.resolve_provider("auto", {"ANTHROPIC_API_KEY": "k", "OPENAI_API_KEY": "k"}) == "anthropic"
    assert models.resolve_provider("auto", {}) == "ollama"
    assert models.resolve_provider("openai", {}) == "openai"


@pytest.mark.parametrize(
    ("provider", "variable"),
    [("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY"), ("openrouter", "OPENROUTER_API_KEY")],
)
def test_a_missing_key_is_a_setup_error(provider, variable):
    with pytest.raises(SetupError, match=variable):
        models.make_model(provider, None, env={})


def test_models_get_defaults_and_overrides():
    assert models.make_model("anthropic", None, env={"ANTHROPIC_API_KEY": "k"}).model == "claude-opus-5"
    assert models.make_model("openai", "my-model", env={"OPENAI_API_KEY": "k"}).model == "my-model"
    router = models.make_model("openrouter", None, env={"OPENROUTER_API_KEY": "k"})
    assert router.base_url == "https://openrouter.ai/api/v1"
    assert models.make_model("ollama", None, env={}).base_url == "http://localhost:11434"
    assert models.make_model("fake", None, env={}).name == "Pip's practice brain"


def test_unknown_provider_is_a_setup_error():
    with pytest.raises(SetupError):
        models.make_model("nope", None, env={})


def test_quota_errors_are_recognised():
    assert is_quota_error(QuotaError("slow down"))
    assert is_quota_error(RuntimeError("HTTP 429 Too Many Requests"))
    assert not is_quota_error(RuntimeError("bad json"))


def test_opencode_builds_the_command_and_reads_stdout(monkeypatch):
    seen = {}

    class Process:
        returncode = 0

        async def communicate(self):
            return b'\x1b[32m{"ok": true}\x1b[0m\n', b""

    async def fake_exec(*argv, **kwargs):
        seen["argv"] = argv
        return Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    model = OpencodeModel("deepseek/deepseek-v4-pro", executable="/bin/opencode")
    answer = asyncio.run(model.complete("quiz", "SYSTEM", "CHAPTER", "PROMPT"))
    assert answer == '{"ok": true}'
    assert seen["argv"][:4] == ("/bin/opencode", "run", "-m", "deepseek/deepseek-v4-pro")
    assert "CHAPTER" in seen["argv"][4] and "PROMPT" in seen["argv"][4]


def test_opencode_rate_limits_become_quota_errors(monkeypatch):
    class Process:
        returncode = 1

        async def communicate(self):
            return b"", b"Error: rate limit exceeded"

    async def fake_exec(*argv, **kwargs):
        return Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    with pytest.raises(QuotaError):
        asyncio.run(OpencodeModel("m", executable="/bin/opencode").complete("quiz", "", "", ""))


def test_opencode_missing_is_a_setup_error(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: None)
    with pytest.raises(SetupError, match="opencode"):
        asyncio.run(OpencodeModel("m").check())


def test_ollama_picks_an_installed_model_and_explains_when_off(monkeypatch):
    from neuralloop_books.models import ollama

    model = ollama.OllamaModel(None)
    monkeypatch.setattr(ollama, "_get_json", lambda url, timeout: {"models": [{"name": "qwen:latest"}]})
    asyncio.run(model.check())
    assert model.model == "qwen:latest"

    def refuse(url, timeout):
        raise OSError("connection refused")

    monkeypatch.setattr(ollama, "_get_json", refuse)
    with pytest.raises(SetupError, match="Ollama isn't running"):
        asyncio.run(ollama.OllamaModel(None).check())


def test_ollama_sends_a_json_chat_with_a_big_context(monkeypatch):
    from neuralloop_books.models import ollama

    sent = {}

    def fake_post(url, body, timeout):
        sent.update(url=url, body=body)
        return {"message": {"content": '{"a": 1}'}}

    monkeypatch.setattr(ollama, "_post_json", fake_post)
    answer = asyncio.run(ollama.OllamaModel("m").complete("quiz", "SYS", "SRC", "ASK"))
    assert answer == '{"a": 1}' and sent["url"].endswith("/api/chat")
    assert "questions" in sent["body"]["format"]["properties"] and sent["body"]["options"]["num_ctx"] >= 16384
    assert 0 < sent["body"]["options"]["num_predict"] <= 16384  # a looping answer can't run forever
    assert sent["body"]["messages"][0] == {"role": "system", "content": "SYS"}


def test_anthropic_streams_with_cached_chapter_and_maps_rate_limits(monkeypatch):
    anthropic = pytest.importorskip("anthropic")
    from neuralloop_books.models.anthropic import AnthropicModel

    captured = {}

    class Stream:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def get_final_message(self):
            return SimpleNamespace(
                stop_reason="end_turn", content=[SimpleNamespace(type="text", text='{"x": 1}')]
            )

    model = AnthropicModel("claude-opus-5", api_key="k")

    def stream(**kwargs):
        captured.update(kwargs)
        return Stream()

    monkeypatch.setattr(model.client.beta.messages, "stream", stream)
    assert asyncio.run(model.complete("quiz", "SYS", "CHAPTER", "ASK")) == '{"x": 1}'
    first_block = captured["messages"][0]["content"][0]
    assert "CHAPTER" in first_block["text"] and first_block["cache_control"] == {"type": "ephemeral"}
    assert captured["thinking"] == {"type": "adaptive"} and captured["model"] == "claude-opus-5"

    def limited(**kwargs):
        response = SimpleNamespace(status_code=429, headers={}, request=None)
        raise anthropic.RateLimitError("slow down", response=response, body=None)

    monkeypatch.setattr(model.client.beta.messages, "stream", limited)
    with pytest.raises(QuotaError):
        asyncio.run(model.complete("quiz", "SYS", "CHAPTER", "ASK"))


def test_ollama_constrains_known_items_with_a_schema(monkeypatch):
    from neuralloop_books.models import ollama

    sent = []
    monkeypatch.setattr(
        ollama, "_post_json", lambda url, body, timeout: sent.append(body) or {"message": {"content": "{}"}}
    )
    asyncio.run(ollama.OllamaModel("m").complete("mindmap", "", "", ""))
    asyncio.run(ollama.OllamaModel("m").complete("something-new", "", "", ""))
    schema = sent[0]["format"]
    assert schema["type"] == "object" and "children" in schema["properties"]
    assert sent[1]["format"] == "json"


def test_every_item_kind_has_a_schema():
    from neuralloop_books.schemas import SCHEMAS

    assert set(SCHEMAS) == {"study", "graph", "quiz", "cards", "mindmap", "audio", "video", "condense"}
    assert all(schema["type"] == "object" and schema["required"] for schema in SCHEMAS.values())
