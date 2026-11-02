"""Kokoro-82M run with ONNX Runtime: phonemes in, 24 kHz audio out."""

import numpy as np
import pytest

from neuralloop_books.speech import kokoro_model as km


def test_the_vocabulary_is_kokoros():
    vocab = km.vocab()
    assert len(vocab) == 114
    assert (vocab[";"], vocab["."], vocab[" "], vocab["ˈ"]) == (1, 4, 16, 156)


def test_tokens_skip_what_the_model_doesnt_know():
    vocab = km.vocab()
    assert km.tokens("hˈæʃ\n", vocab) == [vocab["h"], vocab["ˈ"], vocab["æ"], vocab["ʃ"]]


def test_short_phonemes_are_one_batch():
    assert km.batches("ðə kˈæʃ.") == ["ðə kˈæʃ."]


def test_long_phonemes_split_after_sentences_first():
    one, two = "a" * 300 + ".", "b" * 300 + "!"
    assert km.batches(f"{one} {two}", limit=510) == [one, two]


def test_then_after_clauses_then_between_words():
    clause = "c" * 200 + ","
    batches = km.batches(" ".join([clause] * 3), limit=450)
    assert batches == [f"{clause} {clause}", clause]
    words = km.batches(" ".join(["w" * 99] * 6), limit=250)
    assert all(len(b) <= 250 for b in words) and len(words) == 3


def test_an_unbroken_run_is_cut_rather_than_lost():
    batches = km.batches("x" * 1200, limit=510)
    assert [len(b) for b in batches] == [510, 510, 180]


def test_silence_is_trimmed_from_both_ends():
    quiet, loud = np.zeros(24_000, np.float32), np.full(12_000, 0.5, np.float32)
    trimmed = km.trim(np.concatenate([quiet, loud, quiet]))
    assert 12_000 <= len(trimmed) <= 12_000 + 4096
    assert km.trim(np.zeros(5000, np.float32)).size == 0


def test_a_batch_ending_a_sentence_pauses_longer_than_a_clause():
    assert km.pause_after("ðə ˈɛnd.") > km.pause_after("ænd,") > km.pause_after("ænd") == 0


class FakeSession:
    def __init__(self):
        self.calls = []

    def run(self, outputs, feeds):
        self.calls.append(feeds)
        return [np.full((1, 12_000), 0.3, np.float32)]


@pytest.fixture
def model(tmp_path):
    voices = {"af_heart": np.arange(510 * 256, dtype=np.float32).reshape(510, 1, 256)}
    np.savez(tmp_path / "voices.npz", **voices)
    made = km.KokoroModel.__new__(km.KokoroModel)
    made.session = FakeSession()
    made.voices = dict(np.load(tmp_path / "voices.npz"))
    made.table = km.vocab()
    return made


def test_the_model_gets_padded_tokens_the_style_for_their_length_and_the_speed(model):
    audio = model.create("hˈæʃ.", "af_heart", speed=1.1)
    feeds = model.session.calls[0]
    assert feeds["tokens"].dtype == np.int64 and feeds["tokens"][0, 0] == 0 and feeds["tokens"][0, -1] == 0
    assert feeds["tokens"].shape == (1, 5 + 2)
    assert np.array_equal(feeds["style"], model.voices["af_heart"][5 - 1])
    assert feeds["speed"].dtype == np.float32 and feeds["speed"][0] == pytest.approx(1.1)
    assert audio.dtype == np.float32 and audio.size == 12_000


def test_batches_are_joined_with_a_pause(model):
    first = "a" * 300 + "."
    audio = model.create(f"{first} {'b' * 300}", "af_heart", speed=1.0)
    assert len(model.session.calls) == 2
    assert audio.size == 12_000 * 2 + int(0.25 * km.RATE)


def test_speed_stays_in_the_models_range(model):
    model.create("ɐ", "af_heart", speed=5)
    assert model.session.calls[0]["speed"][0] == 2.0


def test_unknown_voices_and_empty_phonemes(model):
    with pytest.raises(ValueError, match="voice"):
        model.create("ɐ", "nobody", 1.0)
    assert model.create("\n", "af_heart", 1.0).size == 0
