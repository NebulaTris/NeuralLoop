"""Signing in with Google. One real-browser sign-in serves the app (who you are) and NotebookLM (its
session).

NotebookLM has no public API that accepts OAuth tokens, so the session comes from signing in to Google in a
real browser window (Chrome when installed, which Google always accepts), saved by the NotebookLM library.
"""

import contextlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

CHROME = Path("/Applications/Google Chrome.app")
# Without Chrome, sign-in uses Chromium. The runtime's own Playwright folder is inside the signed app
# (read-only; writing there breaks its seal), so a first sign-in downloads Chromium into the person's
# NeuralLoop folder.
BROWSERS = Path.home() / "Library" / "Application Support" / "app.neuralloop.books" / "browsers"
SIGN_IN_TIMEOUT = 600  # seconds for a person to finish signing in


def _cli() -> list[str] | None:
    """The NotebookLM command. Run as a module of this Python, so the app's runtime works wherever it's moved
    (pip's launcher scripts hard-code the path they were installed at)."""
    if importlib.util.find_spec("notebooklm") is not None:
        return [sys.executable, "-m", "notebooklm"]
    found = shutil.which("notebooklm")
    return [found] if found else None


def _chrome_installed() -> bool:
    return CHROME.exists()


def _chromium_downloaded() -> bool:
    """Whether an earlier sign-in already downloaded Chromium (Playwright keeps it in `chromium-<build>`)."""
    try:
        return any(entry.is_dir() and entry.name.startswith("chromium") for entry in BROWSERS.iterdir())
    except OSError:
        return False


def status() -> dict:
    """{"signedIn": bool, "email": str}, from the saved session (quick, no network)."""
    cli = _cli()
    if not cli:
        return {"signedIn": False, "email": ""}
    try:
        result = subprocess.run([*cli, "auth", "check", "--json"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return {"signedIn": False, "email": ""}
    try:
        report = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        report = {}
    email = (report.get("account") or {}).get("email") or ""
    return {"signedIn": result.returncode == 0 and report.get("status") == "ok", "email": email}


def sign_in(log: Callable[[str], None]) -> int:
    """Open a browser window for Google sign-in; print `Account: {json}` when done. Exit code 0 or 3."""
    cli = _cli()
    if not cli:
        log("Google sign-in needs the NotebookLM library. Reinstall NeuralLoop to add it.")
        return 3
    browser = "chrome" if _chrome_installed() else "chromium"
    env = None
    if browser == "chromium":
        BROWSERS.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, "PLAYWRIGHT_BROWSERS_PATH": str(BROWSERS)}
        if not _chromium_downloaded():
            log("  setup: Getting a browser for Google sign-in (the first time only, about 150 MB)…")
    log("  setup: A browser window is opening. Sign in to Google there, then come back.")
    with contextlib.suppress(subprocess.TimeoutExpired):  # the status check below says it didn't finish
        subprocess.run(
            [*cli, "login", "--browser", browser, "--browser-timeout", str(SIGN_IN_TIMEOUT)],
            capture_output=True,
            text=True,
            timeout=SIGN_IN_TIMEOUT + 60,  # never wait forever on a browser that hangs
            env=env,
        )

    now = status()
    if not now["signedIn"]:
        log("Sign-in didn't finish. Click Sign in with Google to try again, or continue without it.")
        return 3
    log("Account: " + json.dumps(now))
    return 0


def sign_out() -> int:
    """Forget the saved Google session (NotebookLM stops being used until the next sign-in)."""
    cli = _cli()
    if not cli:
        return 0
    result = subprocess.run([*cli, "auth", "logout"], capture_output=True, text=True, timeout=60)
    return 0 if result.returncode == 0 else 3


def usage() -> dict:
    """NotebookLM's live usage: how much of the five-hour and weekly windows is left, when each resets, and
    whether it can make a podcast or video right now. {"known": False} when it can't be read."""
    cli = _cli()
    if not cli:
        return {"known": False}
    try:
        result = subprocess.run([*cli, "usage", "--json"], capture_output=True, text=True, timeout=60)
        report = json.loads(result.stdout or "{}") if result.returncode == 0 else {}
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        report = {}
    try:
        return _usage_summary(report)
    except (KeyError, TypeError, ValueError):  # a report in a shape we don't know: say we don't know
        return {"known": False}


def _usage_summary(report) -> dict:
    """The app's summary of `notebooklm usage --json`; raises on a report it doesn't understand."""
    if not isinstance(report, dict) or not report.get("windows"):
        return {"known": False}
    windows = {w.get("kind"): w for w in _dicts(report["windows"])}
    actions = {a.get("kind"): a for a in _dicts(report.get("actions") or [])}

    def window(kind: str) -> dict:
        w = windows.get(kind, {})
        return {
            "remaining": round(float(w.get("remaining_percent", 0)), 1),
            "resetsAt": w.get("resets_at", ""),
        }

    return {
        "known": True,
        "available": bool(report.get("available")) and not report.get("is_exhausted"),
        "fiveHour": window("five_hour"),
        "weekly": window("weekly"),
        "podcast": bool(actions.get("audio_overview", {}).get("has_sufficient_quota")),
        "video": bool(actions.get("video_overview", {}).get("has_sufficient_quota")),
    }


def _dicts(value) -> list:
    """`value` when it is a list of objects (as the report's windows and actions are); TypeError otherwise."""
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise TypeError("expected a list of objects")
    return value
