import pytest

from neuralloop_books.cli import main, parse_args


def test_dry_run_uses_the_bundled_sample(tmp_path):
    args = parse_args(["--dry-run", "--out", str(tmp_path)])
    assert args.book.endswith("sample-book.epub")


def test_rejects_other_file_types(tmp_path):
    (tmp_path / "notes.txt").write_text("x")
    with pytest.raises(SystemExit):
        parse_args([str(tmp_path / "notes.txt")])


def test_bad_media_spec_is_reported_not_crashed(epub, tmp_path, capsys):
    assert main([str(epub), "--dry-run", "--no-open", "--out", str(tmp_path / "o"), "--media", "3-1"]) == 2
    assert "Invalid range" in capsys.readouterr().out


def test_dry_run_end_to_end(epub, tmp_path, capsys):
    assert main([str(epub), "--dry-run", "--no-open", "--out", str(tmp_path / "o")]) == 0
    assert "Book: " in capsys.readouterr().out


def test_new_flags_parse(epub):
    args = parse_args(
        [str(epub), "--provider", "ollama", "--model", "qwen", "--speech", "rumik", "--voices", "Ira,Zoya"]
    )
    assert (args.engine, args.provider, args.model, args.speech, args.voices) == (
        "auto",
        "ollama",
        "qwen",
        "rumik",
        "Ira,Zoya",
    )


def test_a_missing_key_exits_3_with_a_friendly_message(epub, tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    code = main([str(epub), "--provider", "openai", "--no-open", "--out", str(tmp_path / "o")])
    assert code == 3 and "OPENAI_API_KEY" in capsys.readouterr().out


def test_check_ai_tests_every_configured_model_and_reports_json(tmp_path, capsys):
    import json

    config = tmp_path / "ai.json"
    config.write_text(json.dumps({"make": {"provider": "fake"}, "recall": {"provider": "fake"}}))
    assert main(["--check-ai", "--ai-config", str(config)]) == 0
    report = json.loads(capsys.readouterr().out.strip().splitlines()[-1].removeprefix("AI check: "))
    assert (
        report["make"]["ok"] and report["recall"]["ok"] and report["make"]["name"] == "Pip's practice brain"
    )


def test_check_ai_explains_what_is_missing(tmp_path, capsys, monkeypatch):
    import json

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    config = tmp_path / "ai.json"
    config.write_text(json.dumps({"make": {"provider": "anthropic"}, "recall": {"provider": "fake"}}))
    assert main(["--check-ai", "--ai-config", str(config)]) == 3
    report = json.loads(capsys.readouterr().out.strip().splitlines()[-1].removeprefix("AI check: "))
    assert (
        not report["make"]["ok"]
        and "ANTHROPIC_API_KEY" in report["make"]["message"]
        and report["recall"]["ok"]
    )


def test_the_local_fallback_can_start_inside_a_running_book_run(tmp_path, monkeypatch):
    """auto builds the local engine mid-run, inside the event loop; starting Ollama needs no new loop."""
    import asyncio

    from neuralloop_books import cli, setup
    from neuralloop_books.models.fake import FakeModel
    from neuralloop_books.pipeline import Options
    from neuralloop_books.state import BookState

    started = []

    async def fake_ensure(host, log, **kwargs):
        started.append(host)

    monkeypatch.setattr(setup, "ensure_ollama", fake_ensure)
    monkeypatch.setattr(cli, "resolve_provider", lambda provider, env: "ollama")
    monkeypatch.setattr("neuralloop_books.models.make_model", lambda *a, **k: FakeModel())
    opts = Options(book=tmp_path / "b.epub", out=tmp_path, speech="fake", log=lambda _: None)
    state = BookState.create(tmp_path / "state.json", title="T", source="b", chapters=[], dry_run=False)

    async def inside_a_run():
        engine = cli._local_engine(opts)  # what AutoEngine's fallback factory does, mid-run
        await engine.prepare(state)

    asyncio.run(inside_a_run())
    assert started  # Ollama was started from inside the loop


def test_a_broken_book_exits_2_with_a_friendly_message(tmp_path, capsys):
    book = tmp_path / "broken.epub"
    book.write_bytes(b"not a zip at all")
    assert main([str(book), "--dry-run", "--no-open", "--out", str(tmp_path / "o")]) == 2
    assert "This book couldn't be read" in capsys.readouterr().out


def test_only_real_sign_in_problems_are_reported_as_not_signed_in(epub, tmp_path, capsys, monkeypatch):
    from neuralloop_books import cli

    class AuthError(Exception):
        pass

    def fails_with(error):
        async def run(opts, engine):
            raise error

        return run

    args = [str(epub), "--dry-run", "--no-open", "--out", str(tmp_path / "o")]
    monkeypatch.setattr(cli, "run", fails_with(AuthError("session expired")))
    assert main(args) == 3 and "not signed in" in capsys.readouterr().out
    monkeypatch.setattr(cli, "run", fails_with(RuntimeError("Not signed in. Run: notebooklm login")))
    assert main(args) == 3
    monkeypatch.setattr(cli, "run", fails_with(RuntimeError("the book's author field is odd")))
    with pytest.raises(RuntimeError, match="author"):
        main(args)
    monkeypatch.setattr(cli, "run", fails_with(RuntimeError("couldn't write to storage")))
    with pytest.raises(RuntimeError, match="storage"):
        main(args)
