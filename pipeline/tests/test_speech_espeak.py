"""Phonemes for Kokoro from espeak-ng, run as its own program."""

import shutil
import sys

import pytest

from neuralloop_books.models import SetupError
from neuralloop_books.speech import espeak


def test_text_splits_into_words_and_marks():
    assert espeak.split("Hello there! So, today.") == [
        ("Hello there", False),
        ("! ", True),
        ("So", False),
        (", ", True),
        ("today", False),
        (".", True),
    ]


def test_decimal_points_and_thousands_stay_inside_numbers():
    assert espeak.split("Pi is 3.14, and 1,000 users came.") == [
        ("Pi is 3.14", False),
        (", ", True),
        ("and 1,000 users came", False),
        (".", True),
    ]


def test_a_run_of_marks_and_brackets_is_one_mark():
    assert espeak.split('O(n) — "fast"?!') == [
        ("O", False),
        ("(", True),
        ("n", False),
        (') — "', True),
        ("fast", False),
        ('"?!', True),
    ]


def runner_from(table: dict[str, str], calls: list | None = None):
    """A stand-in espeak-ng: each piece's phonemes, a blank line between pieces like the real one."""

    def run(text: str) -> str:
        if calls is not None:
            calls.append(text)
        pieces = text.strip("\n").split("\n\n")
        return "\n\n".join(table[p] for p in pieces) + "\n"

    return run


def test_phonemes_keep_the_punctuation_kokoro_pauses_on():
    run = runner_from({"Hello there": "həlˈoʊ ðˈɛɹ", "So": "sˈoʊ", "today": "tədˈeɪ"})
    assert espeak.phonemize("Hello there! So, today.", run=run) == "həlˈoʊ ðˈɛɹ! sˈoʊ, tədˈeɪ."


def test_one_program_run_does_a_whole_line():
    calls: list[str] = []
    run = runner_from({"a": "ɐ", "b": "bˈiː", "c": "sˈiː"}, calls)
    assert espeak.phonemize("a, b; c.", run=run) == "ɐ, bˈiː; sˈiː."
    assert calls == ["a\n\nb\n\nc\n"]


def test_a_piece_espeak_splits_over_lines_stays_one_piece():
    def run(text: str) -> str:
        return "wˈʌn\ntˈuː\n\nθɹˈiː\n"

    assert espeak.phonemize("one two, three", run=run) == "wˈʌn tˈuː, θɹˈiː"


def test_when_the_pieces_dont_line_up_each_is_asked_alone():
    calls: list[str] = []

    def run(text: str) -> str:
        calls.append(text)
        if "\n\n" in text:
            return "ɐ\n\nhwˈʌt\n\nbˈiː\n"  # three answers for two pieces: can't tell which is which
        return {"a\n": "ɐ\n", "b\n": "bˈiː\n"}[text]

    assert espeak.phonemize("a, b", run=run) == "ɐ, bˈiː"
    assert calls[1:] == ["a\n", "b\n"]


def test_language_switch_flags_are_dropped():
    run = runner_from({"Café au lait": "kˈæfeɪ (fr)o lˈɛ(en)"})
    assert espeak.phonemize("Café au lait", run=run) == "kˈæfeɪ o lˈɛ"


def test_nothing_to_say_runs_nothing():
    calls: list[str] = []
    assert espeak.phonemize(" ... ", run=runner_from({}, calls)) == "..."
    assert calls == []


def test_the_command_reads_utf8_from_stdin_and_says_nothing_aloud(tmp_path):
    exe = tmp_path / "espeak-ng.exe"
    assert espeak.command(str(exe), "en-gb", data=None) == [str(exe), "-q", "--ipa", "-b", "1", "-v", "en-gb"]
    data = tmp_path
    assert espeak.command(str(exe), "en-us", data=data)[-1] == f"--path={data}"


def test_the_program_comes_from_the_override_then_the_app_then_path(tmp_path, monkeypatch):
    own = tmp_path / "own" / "espeak-ng.exe"
    own.parent.mkdir()
    own.write_bytes(b"")
    (own.parent / "espeak-ng-data").mkdir()
    assert espeak.program({"NEURALLOOP_ESPEAK": str(own)}) == (str(own), own.parent)

    bundle = tmp_path / "bundle"
    (bundle / "espeak-ng" / "espeak-ng-data").mkdir(parents=True)
    (bundle / "espeak-ng" / "espeak-ng.exe").write_bytes(b"")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)
    assert espeak.program({}) == (str(bundle / "espeak-ng" / "espeak-ng.exe"), bundle / "espeak-ng")

    monkeypatch.setattr(sys, "frozen", False)
    monkeypatch.setattr(espeak.shutil, "which", lambda name: "/usr/bin/espeak-ng")
    assert espeak.program({}) == ("/usr/bin/espeak-ng", None)


def test_no_espeak_says_how_to_get_it(monkeypatch):
    monkeypatch.setattr(espeak.shutil, "which", lambda name: None)
    with pytest.raises(SetupError, match="espeak-ng"):
        espeak.require({})


REAL = shutil.which("espeak-ng") or __import__("os").environ.get("NEURALLOOP_ESPEAK")


@pytest.mark.skipif(not REAL, reason="espeak-ng isn't installed here")
def test_real_espeak_gives_kokoros_phonemes():
    """What phonemizer (espeak's library) gave Kokoro for the same lines. The program differs in one way: a
    piece with no stressed word at all ("The", "are they") gets a stress mark on its last word."""
    said = espeak.phonemize("Hello there! So, today we're talking about hash maps.")
    assert said == "həlˈoʊ ðˈɛɹ! sˈoʊ, tədˈeɪ wɪɹ tˈɔːkɪŋ ɐbˌaʊt hˈæʃ mˈæps."
    assert espeak.phonemize("Okay.   Let's   go.") == "oʊkˈeɪ. lˈɛts ɡˈoʊ."


def test_espeak_crashing_fails_the_item_not_the_setup(monkeypatch):
    """Only a missing espeak-ng is something to set up; a crash or a hang fails just that podcast or video."""
    import subprocess

    monkeypatch.setattr(espeak, "require", lambda env=None: ("espeak-ng", None))

    def crashed(*args, **kwargs):
        return subprocess.CompletedProcess(args, 3221225477, b"", b"access violation")

    monkeypatch.setattr(espeak.subprocess, "run", crashed)
    with pytest.raises(espeak.EspeakFailed) as error:
        espeak.runner()("hello\n")
    assert not isinstance(error.value, SetupError)

    def hung(*args, **kwargs):
        raise subprocess.TimeoutExpired("espeak-ng", 60)

    monkeypatch.setattr(espeak.subprocess, "run", hung)
    with pytest.raises(espeak.EspeakFailed):
        espeak.runner()("hello\n")
