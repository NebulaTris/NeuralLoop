import asyncio
import json

import pytest

from neuralloop_books import convert
from neuralloop_books.engines.local import LocalEngine
from neuralloop_books.models.fake import FakeModel
from neuralloop_books.speech.fake import FakeSpeech
from neuralloop_books.state import BookState
from neuralloop_books.testing import LONG


@pytest.fixture
def chapter(tmp_path):
    (tmp_path / "chapters").mkdir()
    (tmp_path / "chapters" / "01.md").write_text("# Caching\n\n" + LONG)
    return {"n": 1, "title": "Caching", "file": "01.md"}


def engine_for(tmp_path, model=None, budget=400_000):
    return LocalEngine(
        model or FakeModel(),
        FakeSpeech(),
        tmp_path,
        budget=budget,
        audio="deep-dive",
        video="explainer",
        language="en",
        instructions="",
    )


def make(engine, task, chapter):
    return asyncio.run(engine.make(task, chapter))


@pytest.mark.parametrize("task", ["study", "graph", "quiz", "cards", "mindmap"])
def test_every_light_task_makes_valid_material(tmp_path, chapter, task):
    result = make(engine_for(tmp_path), task, chapter)
    if task == "study":
        assert result["guide"] and len(result["recall"]) == 3
    elif task == "graph":
        assert convert.concept_graph(result["graph"])
    elif task == "quiz":
        assert result["quiz"][0]["options"] and "a" in result["quiz"][0]
    elif task == "cards":
        assert result["cards"][0]["front"]
    else:
        assert result["mindmap"]["name"] == "Caching"


def test_podcast_is_voiced_with_two_voices_and_a_transcript(tmp_path, chapter):
    speech = FakeSpeech()
    engine = LocalEngine(
        FakeModel(),
        speech,
        tmp_path,
        budget=400_000,
        audio="deep-dive",
        video="explainer",
        language="en",
        instructions="",
    )
    result = asyncio.run(engine.make("audio", chapter))
    assert result["audio"].startswith("media/01-podcast.")
    assert (tmp_path / result["audio"]).exists()
    transcript = json.loads((tmp_path / result["transcript"]).read_text())
    assert len({line["voice"] for line in transcript["lines"]}) == 2
    starts = [line["start"] for line in transcript["lines"]]
    assert starts == sorted(starts) and starts[0] == 0
    assert len(speech.spoken) >= len(transcript["lines"])


def test_explainer_has_narration_audio_per_slide(tmp_path, chapter):
    result = make(engine_for(tmp_path), "video", chapter)
    slides = result["explainer"]["slides"]
    assert len(slides) >= 3
    for slide in slides:
        assert (tmp_path / slide["audio"]).exists() and slide["duration"] > 0


class FlakyModel(FakeModel):
    def __init__(self, bad_answers):
        super().__init__()
        self.bad_answers = bad_answers

    async def complete(self, kind, system, source, prompt):
        if self.bad_answers:
            self.bad_answers -= 1
            self.calls.append((kind, prompt))
            return "Sorry, I can't make JSON today."
        return await super().complete(kind, system, source, prompt)


def test_one_bad_answer_is_retried_with_the_problem_explained(tmp_path, chapter):
    model = FlakyModel(bad_answers=1)
    result = make(engine_for(tmp_path, model), "quiz", chapter)
    assert result["quiz"]
    assert len(model.calls) == 2 and "wasn't usable" in model.calls[1][1]


def test_two_bad_answers_fail_clearly(tmp_path, chapter):
    with pytest.raises(ValueError, match="quiz"):
        make(engine_for(tmp_path, FlakyModel(bad_answers=2)), "quiz", chapter)


def test_long_chapters_are_condensed_before_use(tmp_path, chapter):
    model = FakeModel()
    make(engine_for(tmp_path, model, budget=300), "cards", chapter)
    kinds = [kind for kind, *_ in model.calls]
    assert kinds.count("condense") > 1 and kinds[-1] == "cards"
    assert (tmp_path / "raw" / "01-notes.json").exists()


def test_prepare_records_engine_details(tmp_path, chapter):
    state = BookState.create(
        tmp_path / "state.json", title="T", source="b.epub", chapters=[chapter], dry_run=True
    )
    engine = engine_for(tmp_path)
    asyncio.run(engine.prepare(state))
    assert state.data["engine"] == "local" and state.data["provider"] == "fake"


class StingyModel(FakeModel):
    """Answers with a single flashcard the first time."""

    async def complete(self, kind, system, source, prompt):
        self.calls.append((kind, prompt))
        if kind == "cards" and len(self.calls) == 1:
            return json.dumps({"cards": [{"front": "Only one?", "back": "Yes."}]})
        return await FakeModel().complete(kind, system, source, prompt)


def test_too_few_items_are_asked_for_again(tmp_path, chapter):
    model = StingyModel()
    result = make(engine_for(tmp_path, model), "cards", chapter)
    assert len(result["cards"]) == 3
    assert "only 1" in model.calls[1][1]


def test_rejected_answers_are_kept_for_diagnosis(tmp_path, chapter):
    with pytest.raises(ValueError):
        make(engine_for(tmp_path, FlakyModel(bad_answers=2)), "quiz", chapter)
    assert "can't make JSON" in (tmp_path / "raw" / "01-quiz-rejected.txt").read_text()


class EchoModel(FakeModel):
    """Copies the prompt's placeholder text the first time."""

    async def complete(self, kind, system, source, prompt):
        self.calls.append((kind, prompt))
        if len(self.calls) == 1:
            tree = {
                "name": "Caching",
                "children": [{"name": "main branch, 1-4 words"}, {"name": "idea, 1-6 words"}],
            }
            return json.dumps(tree)
        return await FakeModel().complete(kind, system, source, prompt)


def test_copied_placeholder_text_is_rejected(tmp_path, chapter):
    model = EchoModel()
    result = make(engine_for(tmp_path, model), "mindmap", chapter)
    assert "1-4 words" not in json.dumps(result)
    assert "copied" in model.calls[1][1]


class LeakyModel(FakeModel):
    """Valid JSON whose strings swallowed the structure (a curly quote ended a string)."""

    async def complete(self, kind, system, source, prompt):
        self.calls.append((kind, prompt))
        if len(self.calls) == 1:
            tree = {
                "name": "Caching",
                "children": [{"name": "Snapshots”, “Drift”}]}]},{"}, {"name": "Tiers"}],
            }
            return json.dumps(tree)
        return await FakeModel().complete(kind, system, source, prompt)


def test_strings_that_swallowed_json_structure_are_rejected(tmp_path, chapter):
    model = LeakyModel()
    result = make(engine_for(tmp_path, model), "mindmap", chapter)
    assert "Drift”" not in json.dumps(result, ensure_ascii=False)
    assert "straight double quotes" in model.calls[1][1]


def test_podcast_hosts_are_named_after_their_voices(tmp_path, chapter):
    model = FakeModel()
    make(engine_for(tmp_path, model), "audio", chapter)
    prompt = next(p for kind, p in model.calls if kind == "audio")
    assert "Tone A" in prompt and "Tone B" in prompt and "never say" in prompt


class WatchingSpeech(FakeSpeech):
    """Looks at the transcript file each time a new line is voiced."""

    def __init__(self, folder):
        super().__init__()
        self.folder, self.seen = folder, []

    def synth(self, text, voice, delivery, path):
        transcript = self.folder / "media" / "01-podcast.json"
        if transcript.exists():
            self.seen.append(json.loads(transcript.read_text()))
        super().synth(text, voice, delivery, path)


def test_the_podcast_streams_line_by_line_so_playback_can_start_early(tmp_path, chapter):
    speech = WatchingSpeech(tmp_path)
    engine = LocalEngine(
        FakeModel(),
        speech,
        tmp_path,
        budget=400_000,
        audio="deep-dive",
        video="explainer",
        language="en",
        instructions="",
    )
    result = asyncio.run(engine.make("audio", chapter))
    partial = speech.seen[0]  # what the app could play while line 2 was being voiced
    assert partial["complete"] is False and len(partial["lines"]) == 1
    assert (tmp_path / partial["lines"][0]["clip"]).exists()
    final = json.loads((tmp_path / result["transcript"]).read_text())
    assert final["complete"] is True and all("clip" in line for line in final["lines"])
