import asyncio
import json

from neuralloop_books.aiconfig import load
from neuralloop_books.chapters import chapter_size
from neuralloop_books.config import audio_length
from neuralloop_books.engines.notebooklm import NotebookLMEngine
from neuralloop_books.fake_client import ENUMS, FakeClient
from neuralloop_books.pipeline import Options, run


def test_short_chapters_get_short_podcasts_unless_a_length_is_chosen():
    assert audio_length("auto", 5_000) == "short"  # the 2-page MCP chapter got 18 minutes before
    assert audio_length("auto", 200_000) == "default"
    assert audio_length("long", 5_000) == "long" and audio_length("short", 200_000) == "short"
    assert audio_length("something else", 5_000) == "short"


def test_a_chapters_size_comes_from_its_pages_or_its_text(tmp_path):
    (tmp_path / "chapters").mkdir()
    (tmp_path / "chapters" / "02.md").write_text("x" * 1234)
    assert chapter_size({"file": "01.pdf", "pages": [5, 6]}, tmp_path) == 2 * 2_500
    assert chapter_size({"file": "02.md", "pages": None}, tmp_path) == 1234
    assert chapter_size({"file": "03.md", "pages": None}, tmp_path) == 0


def test_the_person_can_choose_a_podcast_length_in_ai_json(tmp_path):
    path = tmp_path / "ai.json"
    path.write_text(json.dumps({"audioLength": "long"}))
    assert load(path).audio_length == "long"
    path.write_text(json.dumps({"audioLength": "forever"}))
    assert load(path).audio_length == "auto"


class RecordingClient(FakeClient):
    def __init__(self):
        super().__init__(delay=0)
        self.audio_requests = []

    async def _generate(self, notebook_id, source_ids=None, **kwargs):
        if "audio_format" in kwargs:
            self.audio_requests.append(kwargs)
        return await super()._generate(notebook_id, source_ids, **kwargs)


def test_notebooklm_is_asked_for_a_short_podcast_for_a_short_chapter(epub, tmp_path):
    opts = Options(book=epub, out=tmp_path / "site", media="1", log=lambda _: None)
    client = RecordingClient()
    asyncio.run(run(opts, NotebookLMEngine(client, ENUMS, opts)))
    assert client.audio_requests and client.audio_requests[0]["audio_length"] == ENUMS.AudioLength.SHORT
