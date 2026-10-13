import wave

import pytest

from neuralloop_books import audio


def write_tone(path, seconds, rate=24000):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(b"\x01\x00" * int(seconds * rate))
    return path


def test_short_text_is_one_piece():
    assert audio.split_for_speech("Hello there.") == ["Hello there."]


def test_long_text_splits_at_sentence_ends_under_the_limit():
    text = " ".join(f"Sentence number {i} is here." for i in range(40))
    pieces = audio.split_for_speech(text, limit=120)
    assert all(len(p) <= 120 for p in pieces)
    assert all(p.endswith(".") for p in pieces)
    assert " ".join(pieces) == text


def test_a_single_huge_sentence_is_split_on_words():
    text = "word " * 100
    pieces = audio.split_for_speech(text.strip(), limit=50)
    assert all(len(p) <= 50 for p in pieces) and " ".join(pieces) == text.strip()


@pytest.mark.parametrize(
    "text",
    ["x" * 120 + " then a short tail.", "Start here. " + "y" * 120 + " end.", "z" * 120],
    ids=["first", "middle", "alone"],
)
def test_a_word_longer_than_the_limit_is_cut_and_no_piece_is_empty(text):
    pieces = audio.split_for_speech(text, limit=50)
    assert all(0 < len(p) <= 50 for p in pieces)
    assert "".join(pieces).replace(" ", "") == text.replace(" ", "")


def test_join_adds_pauses_and_reports_durations(tmp_path):
    parts = [write_tone(tmp_path / "a.wav", 1.0), write_tone(tmp_path / "b.wav", 0.5)]
    durations = audio.join_wavs(parts, tmp_path / "all.wav", pause=0.25)
    assert durations == [1.0, 0.5]
    with wave.open(str(tmp_path / "all.wav")) as joined:
        assert abs(joined.getnframes() / joined.getframerate() - 1.75) < 0.01


def test_to_m4a_uses_afconvert(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(audio.shutil, "which", lambda name: "/usr/bin/afconvert")
    monkeypatch.setattr(audio.subprocess, "run", lambda argv, **kw: calls.append(argv))
    wav = write_tone(tmp_path / "x.wav", 0.1)
    result = audio.to_m4a(wav)
    assert result == tmp_path / "x.m4a"
    assert calls[0][:5] == ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac"]


def test_to_m4a_keeps_the_wav_without_afconvert(tmp_path, monkeypatch):
    monkeypatch.setattr(audio.shutil, "which", lambda name: None)
    wav = write_tone(tmp_path / "x.wav", 0.1)
    assert audio.to_m4a(wav) == wav


def write_level(path, level, seconds=0.5, rate=24000):
    import math
    import struct

    frames = int(seconds * rate)
    samples = (int(level * 32767 * math.sin(2 * math.pi * 220 * i / rate)) for i in range(frames))
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    return path


def rms(path):
    import array
    import math

    with wave.open(str(path)) as clip:
        samples = array.array("h", clip.readframes(clip.getnframes()))
    return math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768


def test_join_evens_out_loudness_between_voices(tmp_path):
    loud, quiet = write_level(tmp_path / "loud.wav", 0.6), write_level(tmp_path / "quiet.wav", 0.05)
    audio.join_wavs([loud, quiet], tmp_path / "all.wav", pause=0)
    with wave.open(str(tmp_path / "all.wav")) as joined:
        half = joined.getnframes() // 2
        first, second = joined.readframes(half), joined.readframes(half)
    for name, frames in (("a", first), ("b", second)):
        with wave.open(str(tmp_path / f"{name}.wav"), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(24000)
            out.writeframes(frames)
    ratio = rms(tmp_path / "a.wav") / rms(tmp_path / "b.wav")
    assert 0.8 < ratio < 1.25


def test_silence_stays_silent(tmp_path):
    silent = write_level(tmp_path / "s.wav", 0.0)
    audio.join_wavs([silent], tmp_path / "all.wav", pause=0)
    assert rms(tmp_path / "all.wav") == 0
