import json
from types import SimpleNamespace

from neuralloop_books import account


def fake_run(responses, calls):
    def run(argv, **kwargs):
        calls.append(argv)
        code, out = responses.pop(0)
        return SimpleNamespace(returncode=code, stdout=out, stderr="")

    return run


def test_status_reports_the_signed_in_google_account(monkeypatch):
    calls = []
    body = json.dumps({"status": "ok", "account": {"email": "pip@example.com"}})
    monkeypatch.setattr(account.subprocess, "run", fake_run([(0, body)], calls))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    assert account.status() == {"signedIn": True, "email": "pip@example.com"}
    assert calls[0][:6] == ["/venv/bin/python", "-m", "notebooklm", "auth", "check", "--json"]


def test_status_when_signed_out_or_not_installed(monkeypatch):
    monkeypatch.setattr(account.subprocess, "run", fake_run([(1, '{"status": "error"}')], []))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    assert account.status() == {"signedIn": False, "email": ""}
    monkeypatch.setattr(account, "_cli", lambda: None)
    assert account.status() == {"signedIn": False, "email": ""}


def test_sign_in_uses_chrome_when_installed_and_reports_the_account(monkeypatch):
    calls, lines = [], []
    ok = json.dumps({"status": "ok", "account": {"email": "pip@example.com"}})
    monkeypatch.setattr(account.subprocess, "run", fake_run([(0, ""), (0, ok)], calls))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    monkeypatch.setattr(account, "_chrome_installed", lambda: True)
    assert account.sign_in(lines.append) == 0
    assert calls[0][:4] == ["/venv/bin/python", "-m", "notebooklm", "login"] and "chrome" in calls[0]
    assert json.loads(lines[-1].removeprefix("Account: ")) == {"signedIn": True, "email": "pip@example.com"}


def test_sign_in_that_does_not_finish_says_how_to_retry(monkeypatch):
    lines = []
    monkeypatch.setattr(account.subprocess, "run", fake_run([(1, ""), (1, "{}")], []))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    monkeypatch.setattr(account, "_chrome_installed", lambda: False)
    assert account.sign_in(lines.append) == 3
    assert "didn't finish" in lines[-1]


def test_status_survives_a_missing_command(monkeypatch):
    def missing(argv, **kwargs):
        raise FileNotFoundError(argv[0])

    monkeypatch.setattr(account.subprocess, "run", missing)
    monkeypatch.setattr(account, "_cli", lambda: ["/gone/notebooklm"])
    assert account.status() == {"signedIn": False, "email": ""}


def test_the_library_runs_through_this_python_so_a_moved_app_still_works(monkeypatch):
    import sys

    # As in the app's runtime, which has notebooklm-py (an optional extra: tests don't need it).
    installed = {"notebooklm": object()}
    monkeypatch.setattr(account.importlib.util, "find_spec", lambda name: installed.get(name))
    monkeypatch.setattr(account.shutil, "which", lambda name: "/somewhere/else/notebooklm")
    assert account._cli() == [sys.executable, "-m", "notebooklm"]


def test_without_the_library_the_notebooklm_command_on_path_is_used(monkeypatch):
    monkeypatch.setattr(account.importlib.util, "find_spec", lambda name: None)
    on_path = {"notebooklm": "/opt/bin/notebooklm"}
    monkeypatch.setattr(account.shutil, "which", lambda name: on_path.get(name))
    assert account._cli() == ["/opt/bin/notebooklm"]
    monkeypatch.setattr(account.shutil, "which", lambda name: None)
    assert account._cli() is None


def test_sign_out_clears_the_saved_session(monkeypatch):
    calls = []
    monkeypatch.setattr(account.subprocess, "run", fake_run([(0, "")], calls))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    assert account.sign_out() == 0
    assert calls[0][-2:] == ["auth", "logout"]


USAGE = {
    "status": "ready",
    "available": True,
    "is_exhausted": False,
    "windows": [
        {
            "kind": "five_hour",
            "used_percent": 40.0,
            "remaining_percent": 60.0,
            "resets_at": "2026-09-29T10:21:40+00:00",
        },
        {
            "kind": "weekly",
            "used_percent": 7.7,
            "remaining_percent": 92.3,
            "resets_at": "2026-10-04T13:21:40+00:00",
        },
    ],
    "actions": [
        {"kind": "audio_overview", "has_sufficient_quota": True, "estimated_cost_percent": 44.1},
        {"kind": "video_overview", "has_sufficient_quota": False, "estimated_cost_percent": 43.7},
    ],
}


def test_usage_summarises_notebooklms_windows_and_what_it_can_still_make(monkeypatch):
    calls = []
    monkeypatch.setattr(account.subprocess, "run", fake_run([(0, json.dumps(USAGE))], calls))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    usage = account.usage()
    assert calls[0][-2:] == ["usage", "--json"]
    assert usage["fiveHour"] == {"remaining": 60.0, "resetsAt": "2026-09-29T10:21:40+00:00"}
    assert usage["weekly"]["remaining"] == 92.3 and usage["podcast"] is True and usage["video"] is False
    assert usage["available"] is True


def test_usage_when_signed_out_or_unknown(monkeypatch):
    monkeypatch.setattr(account.subprocess, "run", fake_run([(1, "")], []))
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    assert account.usage() == {"known": False}


def test_a_sign_in_browser_that_hangs_is_given_up_on(monkeypatch):
    import subprocess

    lines, seen = [], {}

    def run(argv, **kwargs):
        if "login" in argv:
            seen["timeout"] = kwargs.get("timeout")
            raise subprocess.TimeoutExpired(argv, kwargs.get("timeout"))
        return SimpleNamespace(returncode=1, stdout="{}", stderr="")

    monkeypatch.setattr(account.subprocess, "run", run)
    monkeypatch.setattr(account, "_cli", lambda: ["/venv/bin/python", "-m", "notebooklm"])
    monkeypatch.setattr(account, "_chrome_installed", lambda: False)
    assert account.sign_in(lines.append) == 3
    assert seen["timeout"] and seen["timeout"] > account.SIGN_IN_TIMEOUT
