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


def test_notebooklm_work_uses_two_lanes_even_when_the_fallback_would_be_ollama(epub, monkeypatch):
    from neuralloop_books import cli

    for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NEURALLOOP_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(cli, "resolve_provider", lambda provider, env: "ollama")
    assert cli._default_parallel(parse_args([str(epub), "--engine", "auto", "--provider", "auto"])) == 2
    assert cli._default_parallel(parse_args([str(epub), "--engine", "local", "--provider", "ollama"])) == 1


@pytest.mark.parametrize("given", ["0", "-100", "12"])
def test_a_tiny_or_negative_context_is_raised_to_a_workable_size(epub, given):
    from neuralloop_books import cli

    assert cli._context(parse_args([str(epub), "--context", given])) == 1_000
    assert cli._context(parse_args([str(epub), "--context", "50000"])) == 50_000
    assert cli._context(parse_args([str(epub)])) is None


def test_notebooklm_engine_without_its_library_is_a_setup_problem(epub, tmp_path, capsys, monkeypatch):
    import builtins

    real_import = builtins.__import__

    def no_notebooklm(name, *args, **kwargs):
        if name == "notebooklm":
            raise ImportError("No module named 'notebooklm'")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", no_notebooklm)
    code = main([str(epub), "--engine", "notebooklm", "--no-open", "--out", str(tmp_path / "o")])
    assert code == 3 and "notebooklm-py" in capsys.readouterr().out


def test_a_corrupt_state_file_does_not_say_the_book_is_unreadable(epub, tmp_path, capsys):
    """Exit 2 makes the app wait for a settings change: only a book that can't be read earns it."""
    out = tmp_path / "o"
    out.mkdir()
    (out / "state.json").write_text('{"chapters": [')
    assert main([str(epub), "--dry-run", "--no-open", "--out", str(out)]) == 0


def test_only_book_problems_exit_2_and_other_value_errors_are_not_mistaken_for_one(
    epub, tmp_path, monkeypatch
):
    import json

    from neuralloop_books import cli

    async def fails(opts, engine):
        json.loads("{broken")

    monkeypatch.setattr(cli, "run", fails)
    with pytest.raises(ValueError):
        main([str(epub), "--dry-run", "--no-open", "--out", str(tmp_path / "o")])


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


def test_a_dry_run_never_uses_the_models_named_in_ai_json(epub, tmp_path, monkeypatch):
    import json

    from neuralloop_books import models

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-not-a-real-key-000000")
    config = tmp_path / "ai.json"
    config.write_text(
        json.dumps(
            {
                "make": {"provider": "anthropic"},
                "tasks": {"quiz": {"provider": "anthropic"}, "audio": {"provider": "openai"}},
                "recall": {"provider": "anthropic"},
            }
        )
    )
    made = []
    real = models.make_model
    monkeypatch.setattr(models, "make_model", lambda p, *a, **k: made.append(p) or real(p, *a, **k))
    code = main([str(epub), "--dry-run", "--ai-config", str(config), "--out", str(tmp_path / "o")])
    assert code == 0 and set(made) == {"fake"}


def test_a_title_starting_with_a_dash_is_read_as_the_title(epub):
    """The app sends `--title=<t>` as one argument, so a book called "-Draft" isn't taken for a flag."""
    assert parse_args([str(epub), "--title=-Draft"]).title == "-Draft"
