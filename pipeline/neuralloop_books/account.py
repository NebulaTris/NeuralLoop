"""Signing in with Google. One real-browser sign-in serves the app (who you are) and NotebookLM (its
session).

NotebookLM has no public API that accepts OAuth tokens, so the session comes from signing in to Google in a
real browser window (Chrome when installed, which Google always accepts), saved by the NotebookLM library.
"""

import json
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

CHROME = Path("/Applications/Google Chrome.app")
SIGN_IN_TIMEOUT = 600  # seconds for a person to finish signing in


def _cli() -> str | None:
    """The NotebookLM command next to this Python (the app's bundled runtime), or on PATH."""
    local = Path(sys.executable).with_name("notebooklm")
    return str(local) if local.exists() else shutil.which("notebooklm")


def _chrome_installed() -> bool:
    return CHROME.exists()


def status() -> dict:
    """{"signedIn": bool, "email": str}, from the saved session (quick, no network)."""
    cli = _cli()
    if not cli:
        return {"signedIn": False, "email": ""}
    result = subprocess.run([cli, "auth", "check", "--json"], capture_output=True, text=True, timeout=30)
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
    log("  setup: A browser window is opening. Sign in to Google there, then come back.")
    subprocess.run(
        [cli, "login", "--browser", browser, "--browser-timeout", str(SIGN_IN_TIMEOUT)],
        capture_output=True,
        text=True,
    )
    now = status()
    if not now["signedIn"]:
        log("Sign-in didn't finish. Click Sign in with Google to try again, or continue without it.")
        return 3
    log("Account: " + json.dumps(now))
    return 0
