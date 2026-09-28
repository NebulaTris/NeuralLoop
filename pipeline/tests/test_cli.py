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
    assert "Study site:" in capsys.readouterr().out


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
