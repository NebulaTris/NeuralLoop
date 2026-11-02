import pytest

from neuralloop_books import speech
from neuralloop_books.models import SetupError
from neuralloop_books.speech.rumik import RumikSpeech, model_for

GB = 1024**3


def test_rumik_is_the_voice_on_apple_silicon_and_kokoro_elsewhere(monkeypatch):
    from neuralloop_books.speech.kokoro import KokoroSpeech

    monkeypatch.setattr(speech.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(speech.platform, "machine", lambda: "arm64")
    assert isinstance(speech.make_speech("auto"), RumikSpeech)
    for system in ("Windows", "Linux"):
        monkeypatch.setattr(speech.platform, "system", lambda system=system: system)
        monkeypatch.setattr(speech.platform, "machine", lambda: "x86_64")
        assert isinstance(speech.make_speech("auto"), KokoroSpeech)
    assert isinstance(speech.make_speech("rumik", "Aisha,Siya"), RumikSpeech)
    assert isinstance(speech.make_speech("kokoro", "af_bella,am_adam"), KokoroSpeech)
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


def test_an_intel_mac_is_told_plainly_instead_of_being_sent_to_kokoro(monkeypatch):
    """The Mac's runtime has no Kokoro (no onnxruntime, no espeak-ng): an Intel Mac gets a clear message."""
    monkeypatch.setattr(speech.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(speech.platform, "machine", lambda: "x86_64")
    voice = speech.make_speech("auto")
    with pytest.raises(SetupError, match="Apple silicon") as error:
        voice.check()
    assert "NotebookLM" in str(error.value)


@pytest.mark.parametrize(
    ("voice", "name"),
    [("af_heart", "Heart"), ("am_michael", "Michael"), ("bm_george", "George"), ("ef_dora", "Dora"),
     ("Ira", "Ira"), ("Tone A", "Tone A")],
)  # fmt: skip
def test_podcast_hosts_have_names_people_can_say(voice, name):
    """The script's hosts are called by name; a voice id like af_heart is never read out."""
    assert speech.host_name(voice) == name
