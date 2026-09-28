"""First-run setup, so NeuralLoop works out of the box: start Ollama (the app's bundled copy, or one already
installed), download the default local model, and download Rumik's voices. Progress lines start with
"  setup:" so the desktop app can show them.
"""

import asyncio
import json
import os
import shutil
import subprocess
import urllib.request
from collections.abc import Callable, Iterator

from .models import SetupError

_GB = 1024**3
DEFAULT_HOST = "http://127.0.0.1:11434"


def total_memory() -> int:
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")


def local_model_for_memory(memory: int) -> str:
    """The model that runs comfortably next to Rumik's voices."""
    return "qwen3:8b" if memory >= 16 * _GB else "qwen3:4b"


def ollama_host() -> str:
    host = os.environ.get("OLLAMA_HOST", "") or DEFAULT_HOST
    return host if host.startswith("http") else f"http://{host}"


def _ollama_up(host: str) -> bool:
    try:
        with urllib.request.urlopen(f"{host}/api/version", timeout=2):
            return True
    except OSError:
        return False


def _spawn(argv: list[str], env: dict) -> None:
    subprocess.Popen(
        argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True
    )


async def ensure_ollama(host: str, log: Callable[[str], None], wait: float = 0.5, attempts: int = 60) -> None:
    """Use a running Ollama, or start the bundled one (NEURALLOOP_OLLAMA) or an installed one."""
    if _ollama_up(host):
        return
    binary = os.environ.get("NEURALLOOP_OLLAMA") or shutil.which("ollama")
    if not binary or not os.path.exists(binary):
        raise SetupError("Ollama isn't running and isn't installed. Reinstall NeuralLoop, or install Ollama.")
    log("  setup: Starting Pip's local brain (Ollama)…")
    env = {**os.environ, "OLLAMA_HOST": host.split("://", 1)[-1]}
    if os.environ.get("NEURALLOOP_MODELS_DIR"):
        env["OLLAMA_MODELS"] = os.environ["NEURALLOOP_MODELS_DIR"]
    _spawn([binary, "serve"], env)
    for _ in range(attempts):
        await asyncio.sleep(wait)
        if _ollama_up(host):
            return
    raise SetupError("Ollama isn't running: it didn't start. Restart your Mac, then open NeuralLoop again.")


def _installed_models(host: str) -> list[str]:
    with urllib.request.urlopen(f"{host}/api/tags", timeout=5) as response:
        return [m["name"] for m in json.load(response).get("models", [])]


def _stream_pull(host: str, name: str) -> Iterator[dict]:
    body = json.dumps({"model": name, "stream": True}).encode()
    request = urllib.request.Request(
        f"{host}/api/pull", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=3600) as response:
        for line in response:
            if line.strip():
                yield json.loads(line)


async def ensure_model(host: str, name: str, log: Callable[[str], None]) -> None:
    installed = _installed_models(host)
    if name in installed or f"{name}:latest" in installed:
        return

    def pull() -> None:
        last = -1
        for event in _stream_pull(host, name):
            if event.get("error"):
                raise SetupError(f"Couldn't download {name}: {event['error']}")
            if event.get("total"):
                percent = int(100 * event.get("completed", 0) / event["total"])
                if percent >= last + 5:
                    log(f"  setup: downloading {name} {percent}%")
                    last = percent

    log(f"  setup: downloading {name} (a few GB, once)…")
    await asyncio.to_thread(pull)
    log(f"  setup: {name} ready")


async def ensure_rumik(log: Callable[[str], None]) -> None:
    from .speech.rumik import RumikSpeech

    speech = RumikSpeech(None)
    speech.check()
    log(f"  setup: getting Rumik's voices ready ({speech.model.rsplit('-', 1)[-1]}, a few GB, once)…")
    await asyncio.to_thread(speech.load)
    log("  setup: Rumik ready")


async def run_setup(log: Callable[[str], None], model: str | None = None, recall_model=None) -> None:
    host = ollama_host()
    await ensure_ollama(host, log)
    await ensure_model(host, model or local_model_for_memory(total_memory()), log)
    if recall_model is not None and recall_model.provider == "ollama" and recall_model.model:
        await ensure_model(host, recall_model.model, log)
    await ensure_rumik(log)
    log("Setup: ready")
