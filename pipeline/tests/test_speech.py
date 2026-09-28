import pytest

from neuralloop_books import speech
from neuralloop_books.models import SetupError
from neuralloop_books.speech.rumik import RumikSpeech, model_for_memory

GB = 1024**3


def test_rumik_is_the_voice_and_macos_voices_are_gone():
    assert isinstance(speech.make_speech("auto"), RumikSpeech)
    assert isinstance(speech.make_speech("rumik", "Aisha,Siya"), RumikSpeech)
    with pytest.raises(SetupError):
        speech.make_speech("say")


def test_rumik_picks_the_model_that_fits_in_memory():
    assert model_for_memory(24 * GB).endswith("mlx-8bit")
    assert model_for_memory(16 * GB).endswith("mlx-8bit")
    assert model_for_memory(8 * GB).endswith("mlx-4bit")


def test_rumik_rejects_unknown_voices():
    with pytest.raises(SetupError, match="Ira"):
        RumikSpeech(("Samantha", "Daniel")).check()


def test_two_voices_are_required():
    with pytest.raises(SetupError):
        speech.make_speech("rumik", "Ira")
