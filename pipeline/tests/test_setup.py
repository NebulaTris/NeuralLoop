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
