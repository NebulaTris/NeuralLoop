"""Any model opencode is set up for (for example DeepSeek), through `opencode run` without its TUI.

opencode is a coding agent: left to its defaults, `opencode run` lets the model run shell commands and edit
files. The chapter is part of the prompt, so a book could ask the model to do exactly that. NeuralLoop only
needs text back, so every tool is denied (the model isn't even offered one), the person's project config is
ignored, and it runs in an empty folder with a minimal environment (none of our providers' keys). opencode 2
serves every `run` from one background service with the person's own settings, where these rules wouldn't
apply; so a private server (`--standalone`) is required, and an opencode without it must be updated first.
The person's global opencode config is layered after our rules (the last matching rule wins), so an agent
permission there (`agent.build.permission.bash: allow`) would switch tools back on: opencode runs with its
home and config folders pointed at the empty folder, keeping only its data (sign-ins) and cache folders.
Only the providers and default models from that config are passed on (`persons_settings`), so models set
up there (a custom server, LM Studio, `{env:…}` keys) still work.
"""

import asyncio
import json
import os
import re
import shutil
import tempfile
from collections.abc import Mapping
from pathlib import Path

from ..prompts import wrap_chapter
from . import KEY_VARIABLES, QuotaError, SetupError, agent_env, communicate

TIMEOUT = 1800.0
PROBE_TIMEOUT = 20.0
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_QUOTA_HINTS = ("rate limit", "ratelimit", "quota", "429", "insufficient", "credit")
NO_TOOLS = json.dumps({"permission": {"*": "deny"}})
_standalone: dict[str, bool] = {}  # executable -> whether its `run` has --standalone
FREE_TIER = (
    "opencode's free models only work inside opencode itself. Type a model you've connected in opencode in "
    "Settings (for example deepseek/deepseek-v4-pro), or choose another AI."
)
UPDATE = (
    "Update opencode to use it safely: this version can't run on a private server, so NeuralLoop can't "
    "switch its tools off. Run: opencode upgrade"
)


# From the person's global config, only what says which AI to use: their providers (a custom server, LM
# Studio through opencode, `{env:…}` keys) and default models. Never agents, permissions, MCP servers,
# plugins, commands, tools, instructions: any of those could switch tools back on or run something.
CARRIED = ("provider", "model", "small_model")
MAX_CONFIG_BYTES = 1_000_000
_ENV_REFERENCE = re.compile(r"\{env:([A-Za-z_][A-Za-z0-9_]*)\}")
_FILE_REFERENCE = re.compile(r"\{file:([^}]+)\}")
# Variables a config may not pull in through `{env:…}`: opencode's own settings, and ones that load code.
_NEVER_FORWARDED = ("OPENCODE", "DYLD_", "LD_", "NODE_", "BUN_", "NPM_", "PYTHON", "PERL", "RUBY")


def _config_files(env: Mapping[str, str], home: Path) -> list[Path]:
    """Where opencode looks for the person's global config, in the order it layers them."""
    config = Path(env.get("XDG_CONFIG_HOME") or home / ".config") / "opencode"
    return [
        home / ".opencode.json",
        home / ".opencode" / "opencode.json",
        home / ".opencode" / "opencode.jsonc",
        config / "config.json",
        config / "opencode.json",
        config / "opencode.jsonc",
    ]


def _without_comments(text: str) -> str:
    """JSONC as JSON: `//` and `/* */` comments and trailing commas removed (never inside strings)."""
    return _strip(_strip(text, comments=True), comments=False)


def _strip(text: str, comments: bool) -> str:
    """One pass over `text` outside strings: comments out, or (once they're gone) trailing commas out."""
    out: list[str] = []
    i, n, in_string = 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif comments and text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        elif comments and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        elif not comments and c == ",":
            rest = i + 1
            while rest < n and text[rest] in " \t\r\n":
                rest += 1
            if rest < n and text[rest] in "}]":
                i += 1
                continue
            out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _read_config(path: Path) -> dict | None:
    try:
        if not path.is_file() or path.stat().st_size > MAX_CONFIG_BYTES:
            return None
        data = json.loads(_without_comments(path.read_text(encoding="utf-8-sig")))  # a BOM is fine
    except (OSError, UnicodeDecodeError, ValueError):  # unreadable or not JSON: as if it weren't there
        return None
    return data if isinstance(data, dict) else None


def _absolute_files(value, home: Path, folder: Path):
    """`{file:~/key}` and `{file:./key}` resolve against the person's home and config folder, which
    opencode itself no longer sees."""
    if isinstance(value, dict):
        return {key: _absolute_files(item, home, folder) for key, item in value.items()}
    if isinstance(value, list):
        return [_absolute_files(item, home, folder) for item in value]
    if not isinstance(value, str):
        return value

    def absolute(match: re.Match) -> str:
        path = match.group(1)
        if path.startswith("~/"):
            path = str(home / path[2:])
        elif not path.startswith("/"):
            path = str(folder / path)
        return f"{{file:{path}}}"

    return _FILE_REFERENCE.sub(absolute, value)


def persons_settings(env: Mapping[str, str], home: Path) -> dict:
    """`provider`, `model` and `small_model` from the person's global opencode config, nothing else."""
    carried: dict = {}
    for path in _config_files(env, home):
        config = _read_config(path)
        if config is None:
            continue
        providers = config.get("provider")
        if isinstance(providers, dict):
            for name, provider in providers.items():
                if isinstance(name, str) and isinstance(provider, dict):
                    carried.setdefault("provider", {})[name] = _absolute_files(provider, home, path.parent)
        for key in ("model", "small_model"):
            if isinstance(config.get(key), str) and config[key].strip():
                carried[key] = config[key]
    return {key: carried[key] for key in CARRIED if key in carried}


def locked_down_env(empty: str, env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Only the basics, and none of the person's own opencode settings that could turn tools back on:
    home and config are the `empty` folder; data (where `opencode auth login` keeps sign-ins), cache, and
    state stay the person's own. Their providers and default models come along in the config we pass,
    with the variables their `{env:…}` keys name (never our providers' keys)."""
    env = os.environ if env is None else env
    home = Path(env.get("HOME") or Path.home())
    own = {
        "XDG_DATA_HOME": env.get("XDG_DATA_HOME") or str(home / ".local" / "share"),
        "XDG_CACHE_HOME": env.get("XDG_CACHE_HOME") or str(home / ".cache"),
        "XDG_STATE_HOME": env.get("XDG_STATE_HOME") or str(home / ".local" / "state"),
    }
    settings = persons_settings(env, home)
    locked = {
        **agent_env(env=env),
        **own,
        "HOME": empty,
        "XDG_CONFIG_HOME": str(Path(empty) / "config"),
        "OPENCODE_CONFIG_CONTENT": json.dumps({**json.loads(NO_TOOLS), **settings}) if settings else NO_TOOLS,
        "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
    }
    for name in _ENV_REFERENCE.findall(json.dumps(settings)):
        if (
            name in env
            and name not in locked
            and name not in KEY_VARIABLES
            and not name.upper().startswith(_NEVER_FORWARDED)
        ):
            locked[name] = env[name]
    return locked


class OpencodeModel:
    name = "opencode"
    provider = "opencode"

    def __init__(self, model: str | None, executable: str | None = None):
        if model and model.startswith("-"):
            raise SetupError(f"{model} isn't a model name opencode knows. Check it in Settings.")
        self.model = model
        self.executable = executable

    async def check(self) -> None:
        self.executable = self.executable or shutil.which("opencode")
        if not self.executable:
            raise SetupError("opencode isn't installed. Install it from https://opencode.ai, then run again.")
        if not await self._has_standalone():
            raise SetupError(UPDATE)

    async def _has_standalone(self) -> bool:
        if self.executable not in _standalone:
            try:
                with tempfile.TemporaryDirectory(prefix="neuralloop-opencode-") as empty:
                    process = await asyncio.create_subprocess_exec(
                        self.executable,
                        "run",
                        "--help",
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                        cwd=empty,
                        env=locked_down_env(empty),
                    )
                    stdout, stderr = await communicate(process, min(PROBE_TIMEOUT, TIMEOUT))
                _standalone[self.executable] = b"--standalone" in stdout + stderr
            except (OSError, asyncio.TimeoutError, TimeoutError):  # an old or odd opencode: not safe to run
                _standalone[self.executable] = False
        return _standalone[self.executable]

    async def complete(
        self, kind: str, system: str, source: str, prompt: str, schema: dict | None = None
    ) -> str:
        await self.check()
        message = f"{system}\n\n{wrap_chapter(source)}\n\n{prompt}"
        argv = [self.executable, "run", "--standalone", *(["-m", self.model] if self.model else []), message]
        with tempfile.TemporaryDirectory(prefix="neuralloop-opencode-") as empty:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=empty,
                env=locked_down_env(empty),
            )
            stdout, stderr = await communicate(process, TIMEOUT)
        if process.returncode != 0:
            detail = _ANSI.sub("", stderr.decode(errors="replace")).strip()
            if "free tier can only be used from within opencode" in detail.lower():
                raise SetupError(FREE_TIER)
            if any(hint in detail.lower() for hint in _QUOTA_HINTS):
                raise QuotaError(detail[:200])
            raise RuntimeError(f"opencode failed: {detail[:200]}")
        return _ANSI.sub("", stdout.decode(errors="replace")).strip()
