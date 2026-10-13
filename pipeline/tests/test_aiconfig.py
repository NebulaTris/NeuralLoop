import asyncio
import json

import pytest

from neuralloop_books import aiconfig
from neuralloop_books.engines.local import LocalEngine
from neuralloop_books.models.fake import FakeModel
from neuralloop_books.speech.fake import FakeSpeech
from neuralloop_books.testing import LONG


def test_defaults_work_out_of_the_box(tmp_path):
    config = aiconfig.load(tmp_path / "missing.json")
    assert config.engine == "auto" and config.make.provider == "auto"
    assert config.recall.provider == "ollama" and config.recall.model == "gemma2:2b"
    assert config.voices == ("Ira", "Zoya")


def test_a_person_can_choose_models_per_item(tmp_path):
    path = tmp_path / "ai.json"
    path.write_text(
        json.dumps(
            {
                "engine": "local",
                "make": {"provider": "ollama", "model": "qwen3:8b"},
                "tasks": {"quiz": {"provider": "anthropic", "model": "claude-opus-5"}},
                "recall": {
                    "provider": "custom",
                    "model": "Hermes-4-70B",
                    "baseUrl": "https://api.example.ai/v1",
                },
                "voices": ["Aisha", "Siya"],
            }
        )
    )
    config = aiconfig.load(path)
    assert config.engine == "local" and config.make.model == "qwen3:8b"
    assert config.task("quiz").provider == "anthropic" and config.task("cards").model == "qwen3:8b"
    assert config.recall.base_url == "https://api.example.ai/v1" and config.voices == ("Aisha", "Siya")


def test_a_broken_file_falls_back_to_defaults(tmp_path):
    path = tmp_path / "ai.json"
    path.write_text("{not json")
    assert aiconfig.load(path).engine == "auto"


class Named(FakeModel):
    def __init__(self, name):
        super().__init__()
        self.name = name


def test_the_local_engine_uses_each_items_own_model(tmp_path):
    (tmp_path / "chapters").mkdir()
    (tmp_path / "chapters" / "01.md").write_text(LONG)
    default, quiz_model = Named("Ollama"), Named("Claude")
    engine = LocalEngine(
        default,
        FakeSpeech(),
        tmp_path,
        budget=400_000,
        audio="deep-dive",
        video="explainer",
        language="en",
        instructions="",
        task_models={"quiz": quiz_model},
    )
    chapter = {"n": 1, "title": "Caching", "file": "01.md"}
    asyncio.run(engine.make("quiz", chapter))
    asyncio.run(engine.make("cards", chapter))
    assert [k for k, _ in quiz_model.calls] == ["quiz"] and [k for k, _ in default.calls] == ["cards"]


def test_a_choice_never_borrows_another_providers_model(tmp_path):
    """Settings leaves the model empty for LM Studio, Ollama's default, opencode, and Hermes: such a choice
    must not inherit the main model's name (or recall's gemma2:2b), which belongs to a different provider."""
    path = tmp_path / "ai.json"
    lm_studio = {"provider": "custom", "baseUrl": "http://localhost:1234/v1"}
    path.write_text(
        json.dumps(
            {
                "make": {"provider": "anthropic", "model": "claude-opus-5-5"},
                "tasks": {
                    "quiz": {"provider": "ollama"},
                    "cards": {"provider": "anthropic"},
                    "audio": lm_studio,
                },
                "recall": lm_studio,
            }
        )
    )
    config = aiconfig.load(path)
    assert config.task("quiz") == aiconfig.ModelChoice("ollama")
    assert config.task("cards") == aiconfig.ModelChoice("anthropic", "claude-opus-5-5")
    assert config.task("audio").model is None and config.recall.model is None
    assert config.recall.base_url == "http://localhost:1234/v1"


@pytest.mark.parametrize(
    "data",
    [
        {"tasks": ["quiz"]},
        {"tasks": "x"},
        {"tasks": {"quiz": "anthropic", "cards": None}},
        {"voices": [1, 2]},
        {"voices": "Ira,Zoya"},
        {"voices": ["Ira", "Zoya", "Mira"]},
        {"make": {"provider": "ollama", "model": 7, "baseUrl": ["x"]}},
        {"make": {"provider": {"x": 1}}},
        {"engine": ["local"], "voiceQuality": [], "audioLength": {}},
    ],
)
def test_a_malformed_file_never_stops_a_book(tmp_path, data):
    path = tmp_path / "ai.json"
    path.write_text(json.dumps(data))
    config = aiconfig.load(path)
    assert len(config.voices) == 2 and all(isinstance(v, str) for v in config.voices)
    assert all(isinstance(v, aiconfig.ModelChoice) for v in config.tasks.values())
    for choice in (config.make, config.recall, *config.tasks.values()):
        assert isinstance(choice.provider, str)
        assert choice.model is None or isinstance(choice.model, str)
        assert choice.base_url is None or isinstance(choice.base_url, str)
    assert isinstance(config.engine, str) and config.audio_length == "auto"


def test_the_good_parts_of_a_malformed_file_are_kept(tmp_path):
    path = tmp_path / "ai.json"
    data = {
        "make": {"provider": "ollama", "model": 7},
        "tasks": {"quiz": {"provider": "anthropic"}, "cards": "nope"},
        "voices": ["Ira", 2],
    }
    path.write_text(json.dumps(data))
    config = aiconfig.load(path)
    assert config.make == aiconfig.ModelChoice("ollama")
    assert config.tasks == {"quiz": aiconfig.ModelChoice("anthropic")}
    assert config.voices == ("Ira", "Zoya")
