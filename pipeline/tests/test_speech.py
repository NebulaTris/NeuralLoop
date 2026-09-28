import pytest

from neuralloop_books import speech
from neuralloop_books.models import SetupError
from neuralloop_books.speech.rumik import RumikSpeech, model_for

GB = 1024**3


def test_rumik_is_the_voice_and_macos_voices_are_gone():
    assert isinstance(speech.make_speech("auto"), RumikSpeech)
    assert isinstance(speech.make_speech("rumik", "Aisha,Siya"), RumikSpeech)
    with pytest.raises(SetupError):
        speech.make_speech("say")


def test_rumik_is_fast_by_default_and_best_on_request():
    assert model_for(24 * GB, "fast").endswith("mlx-4bit")  # about twice as fast
    assert model_for(24 * GB, "best").endswith("mlx-8bit")
    assert model_for(8 * GB, "best").endswith("mlx-4bit")  # 8-bit doesn't fit next to the text model


def test_the_voice_quality_comes_from_the_persons_settings(tmp_path):
    import json

    from neuralloop_books import aiconfig

    path = tmp_path / "ai.json"
    path.write_text(json.dumps({"voiceQuality": "best"}))
    assert aiconfig.load(path).voice_quality == "best"
    assert aiconfig.load(tmp_path / "none.json").voice_quality == "fast"
    assert speech.make_speech("rumik", None, quality="best").quality == "best"


def test_rumik_rejects_unknown_voices():
    with pytest.raises(SetupError, match="Ira"):
        RumikSpeech(("Samantha", "Daniel")).check()


def test_two_voices_are_required():
    with pytest.raises(SetupError):
        speech.make_speech("rumik", "Ira")
