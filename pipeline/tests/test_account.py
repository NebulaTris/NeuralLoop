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
    monkeypatch.setattr(account, "_cli", lambda: "/venv/bin/notebooklm")
    assert account.status() == {"signedIn": True, "email": "pip@example.com"}
    assert calls[0][:4] == ["/venv/bin/notebooklm", "auth", "check", "--json"]


def test_status_when_signed_out_or_not_installed(monkeypatch):
    monkeypatch.setattr(account.subprocess, "run", fake_run([(1, '{"status": "error"}')], []))
    monkeypatch.setattr(account, "_cli", lambda: "/venv/bin/notebooklm")
    assert account.status() == {"signedIn": False, "email": ""}
    monkeypatch.setattr(account, "_cli", lambda: None)
    assert account.status() == {"signedIn": False, "email": ""}


def test_sign_in_uses_chrome_when_installed_and_reports_the_account(monkeypatch):
    calls, lines = [], []
    ok = json.dumps({"status": "ok", "account": {"email": "pip@example.com"}})
    monkeypatch.setattr(account.subprocess, "run", fake_run([(0, ""), (0, ok)], calls))
    monkeypatch.setattr(account, "_cli", lambda: "/venv/bin/notebooklm")
    monkeypatch.setattr(account, "_chrome_installed", lambda: True)
    assert account.sign_in(lines.append) == 0
    assert calls[0][:2] == ["/venv/bin/notebooklm", "login"] and "chrome" in calls[0]
    assert json.loads(lines[-1].removeprefix("Account: ")) == {"signedIn": True, "email": "pip@example.com"}


def test_sign_in_that_does_not_finish_says_how_to_retry(monkeypatch):
    lines = []
    monkeypatch.setattr(account.subprocess, "run", fake_run([(1, ""), (1, "{}")], []))
    monkeypatch.setattr(account, "_cli", lambda: "/venv/bin/notebooklm")
    monkeypatch.setattr(account, "_chrome_installed", lambda: False)
    assert account.sign_in(lines.append) == 3
    assert "didn't finish" in lines[-1]
