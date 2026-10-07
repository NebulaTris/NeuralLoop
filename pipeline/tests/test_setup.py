import asyncio

import pytest

from neuralloop_books import setup
from neuralloop_books.models import SetupError

GB = 1024**3


def test_default_local_model_fits_the_mac():
    assert setup.local_model_for_memory(24 * GB) == "qwen3:8b"
    assert setup.local_model_for_memory(8 * GB) == "qwen3:4b"


def test_a_running_ollama_is_reused(monkeypatch):
    monkeypatch.setattr(setup, "_ollama_up", lambda host: True)
    started = []
    monkeypatch.setattr(setup, "_spawn", lambda *a, **k: started.append(a))
    asyncio.run(setup.ensure_ollama("http://localhost:11434", log=lambda _: None))
    assert started == []


def test_the_bundled_ollama_is_started_when_none_is_running(monkeypatch, tmp_path):
    binary = tmp_path / "ollama"
    binary.write_text("#!/bin/sh\n")
    calls = {"up": 0}

    def up(host):
        calls["up"] += 1
        return calls["up"] > 2

    started = []
    monkeypatch.setattr(setup, "_ollama_up", up)
    monkeypatch.setattr(setup, "_spawn", lambda argv, env: started.append((argv, env)))
    monkeypatch.setenv("NEURALLOOP_OLLAMA", str(binary))
    lines = []
    asyncio.run(setup.ensure_ollama("http://127.0.0.1:11434", log=lines.append, wait=0.01))
    assert started[0][0] == [str(binary), "serve"] and started[0][1]["OLLAMA_HOST"] == "127.0.0.1:11434"
    assert any("Starting" in line for line in lines)


def test_no_ollama_anywhere_is_a_setup_error(monkeypatch):
    monkeypatch.setattr(setup, "_ollama_up", lambda host: False)
    monkeypatch.delenv("NEURALLOOP_OLLAMA", raising=False)
    monkeypatch.setattr(setup.shutil, "which", lambda name: None)
    with pytest.raises(SetupError, match="Ollama"):
        asyncio.run(setup.ensure_ollama("http://localhost:11434", log=lambda _: None, wait=0.01))


def test_model_download_reports_progress(monkeypatch):
    events = [
        {"status": "pulling manifest"},
        {"status": "downloading", "total": 100, "completed": 50},
        {"status": "success"},
    ]
    monkeypatch.setattr(setup, "_installed_models", lambda host: [])
    monkeypatch.setattr(setup, "_stream_pull", lambda host, name: iter(events))
    lines = []
    asyncio.run(setup.ensure_model("http://localhost:11434", "qwen3:8b", log=lines.append))
    assert "  setup: downloading qwen3:8b 50%" in lines and lines[-1] == "  setup: qwen3:8b ready"


def test_an_installed_model_is_not_downloaded_again(monkeypatch):
    monkeypatch.setattr(setup, "_installed_models", lambda host: ["qwen3:8b"])
    monkeypatch.setattr(setup, "_stream_pull", lambda host, name: pytest.fail("should not pull"))
    asyncio.run(setup.ensure_model("http://localhost:11434", "qwen3:8b", log=lambda _: None))


def test_the_started_ollama_never_sees_our_keys(monkeypatch, tmp_path):
    binary = tmp_path / "ollama"
    binary.write_text("#!/bin/sh\n")
    calls = {"up": 0}

    def up(host):
        calls["up"] += 1
        return calls["up"] > 1

    keys = {
        "ANTHROPIC_API_KEY": "sk-ant-secret-1234567890",
        "OPENAI_API_KEY": "sk-openai-secret-1234567890",
        "OPENROUTER_API_KEY": "sk-or-secret-1234567890",
        "NEURALLOOP_API_KEY": "my-server-secret",
        "NEURALLOOP_BASE_URL": "https://example.ai/v1",
        "SOME_OTHER_TOKEN": "x-other-secret",
    }
    for name, value in {
        **keys,
        "PATH": "/usr/bin",
        "HOME": "/Users/me",
        "TMPDIR": "/tmp/me",
        "OLLAMA_KEEP_ALIVE": "10m",
        "NEURALLOOP_MODELS_DIR": "/models",
    }.items():
        monkeypatch.setenv(name, value)
    started = []
    monkeypatch.setattr(setup, "_ollama_up", up)
    monkeypatch.setattr(setup, "_spawn", lambda argv, env: started.append(env))
    monkeypatch.setenv("NEURALLOOP_OLLAMA", str(binary))
    asyncio.run(setup.ensure_ollama("http://127.0.0.1:11434", log=lambda _: None, wait=0.01))
    env = started[0]
    assert not set(keys) & set(env)
    assert not any(value in env.values() for value in keys.values())
    assert env["PATH"] == "/usr/bin" and env["HOME"] == "/Users/me" and env["TMPDIR"] == "/tmp/me"
    assert env["OLLAMA_KEEP_ALIVE"] == "10m" and env["OLLAMA_MODELS"] == "/models"
    assert env["OLLAMA_HOST"] == "127.0.0.1:11434"


def test_a_download_inside_a_book_run_shows_as_the_waiting_items_step(monkeypatch, tmp_path):
    import json

    from neuralloop_books.activity import Activity

    seen = []
    feed = Activity(tmp_path, {})

    def pull(host, name):
        yield {"status": "downloading", "total": 100, "completed": 40}
        seen.append(json.loads((tmp_path / "activity.json").read_text())["items"][0])

    monkeypatch.setattr(setup, "_installed_models", lambda host: [])
    monkeypatch.setattr(setup, "_stream_pull", pull)

    async def item():
        token = feed.begin(1, "study", "Ollama")
        await setup.ensure_model("http://localhost:11434", "qwen3:4b", log=lambda _: None)
        feed.end(1, "study", token=token)

    asyncio.run(item())
    assert seen[0]["step"] == "Downloading your Mac's AI (first time only)"


def test_with_no_model_named_any_model_ollama_has_will_do(monkeypatch):
    monkeypatch.setattr(setup, "_installed_models", lambda host: ["llama3:8b"])
    monkeypatch.setattr(setup, "_stream_pull", lambda host, name: pytest.fail("should not pull"))
    asyncio.run(
        setup.ensure_model("http://localhost:11434", "qwen3:8b", log=lambda _: None, any_will_do=True)
    )
