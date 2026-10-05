import asyncio
import json

from neuralloop_books import activity
from neuralloop_books.activity import Activity


def read(out):
    return json.loads((out / "activity.json").read_text())


def test_an_item_being_made_is_written_with_its_step_and_estimate(tmp_path):
    clock = iter([1000.0, 1001.0, 1002.0, 1003.0, 1004.0, 1005.0])
    feed = Activity(tmp_path, timings={"NotebookLM:audio": [400, 500, 600]}, clock=lambda: next(clock))
    feed.queue([(1, "audio"), (1, "video"), (2, "audio")])
    token = feed.begin(1, "audio", "NotebookLM")
    data = read(tmp_path)
    activity._current.reset(token)  # this test runs outside a task: don't leave the item behind for others
    assert data["queue"] == [{"n": 1, "item": "video"}, {"n": 2, "item": "audio"}]
    item = data["items"][0]
    assert (item["n"], item["item"], item["by"]) == (1, "audio", "NotebookLM")
    assert (item["started"], item["expected"]) == (1_000_000, 500)
    assert item["step"] == "" and item["done"] is None and item["total"] is None


def test_steps_are_reported_from_inside_the_item_even_on_another_thread(tmp_path):
    clock = iter([0.0, 1.0, 2.0, 90.0, 90.0])
    feed = Activity(tmp_path, timings={}, clock=lambda: next(clock))

    async def make():
        token = feed.begin(1, "audio", "Ollama")
        activity.report("Writing the podcast script")
        await asyncio.to_thread(activity.report, "Voicing the podcast", done=3, total=12)
        assert read(tmp_path)["items"][0]["step"] == "Voicing the podcast"
        feed.end(1, "audio", seconds=90, ok=True, token=token)

    asyncio.run(make())
    item_after = read(tmp_path)["items"]
    assert item_after == []
    assert feed.timings["Ollama:audio"] == [90]


def test_reporting_outside_an_item_does_nothing(tmp_path):
    activity.report("nobody is listening")  # no error, no file
    assert not (tmp_path / "activity.json").exists()


def test_a_fallback_restarts_the_clock_under_the_new_maker(tmp_path):
    clock = iter([10.0, 400.0, 401.0, 402.0])
    feed = Activity(tmp_path, timings={"Ollama:quiz": [60]}, clock=lambda: next(clock))

    async def make():
        feed.begin(1, "quiz", "NotebookLM")
        activity.report("NotebookLM couldn't; making it with Ollama", by="Ollama", restart=True)
        item = read(tmp_path)["items"][0]
        assert item["by"] == "Ollama" and item["started"] == 400_000 and item["expected"] == 60

    asyncio.run(make())


def test_a_fallback_times_only_the_maker_that_made_the_item(tmp_path):
    """NotebookLM gave up after 900 s and Ollama then took 300 s: Ollama's timing is 300 s, not 1200 s."""
    clock = iter([0.0, 900.0, 1200.0, 1200.0])
    feed = Activity(tmp_path, timings={}, clock=lambda: next(clock))

    async def make():
        token = feed.begin(1, "quiz", "NotebookLM")
        activity.report("NotebookLM couldn't; making it with Ollama", by="Ollama", restart=True)
        feed.end(1, "quiz", seconds=1200, ok=True, token=token)

    asyncio.run(make())
    assert feed.timings == {"Ollama:quiz": [300]}


def test_estimates_come_from_recent_runs_then_sensible_defaults(tmp_path):
    feed = Activity(tmp_path, timings={"NotebookLM:video": [100, 200, 300, 900, 1000, 1100]})
    assert feed.expected("NotebookLM", "video") == 900  # the last five, middle value
    assert feed.expected("NotebookLM", "audio") == activity.DEFAULT_SECONDS[("NotebookLM", "audio")]
    assert feed.expected("Ollama", "audio") is None  # a local podcast reports lines voiced instead
    assert feed.expected("Ollama", "quiz") == activity.DEFAULT_SECONDS[("local", "text")]


def test_failed_items_dont_skew_the_estimates_and_closing_clears_the_feed(tmp_path):
    feed = Activity(tmp_path, timings={})
    token = feed.begin(2, "video", "NotebookLM")
    feed.end(2, "video", seconds=5, ok=False, token=token)
    assert "NotebookLM:video" not in feed.timings
    feed.close()
    data = read(tmp_path)
    assert data["items"] == [] and data["queue"] == [] and data["ended"] is True


def test_an_item_can_report_its_overall_fraction_across_stages(tmp_path):
    feed = Activity(tmp_path, timings={})

    async def make():
        token = feed.begin(1, "video", "Ollama")
        activity.report("Drawing the video", done=50, total=100, fraction=0.69)
        item = read(tmp_path)["items"][0]
        assert item["fraction"] == 0.69 and (item["done"], item["total"]) == (50, 100)
        activity.report("Finishing the video", fraction=1.7)  # never more than all of it
        assert read(tmp_path)["items"][0]["fraction"] == 1.0
        feed.end(1, "video", seconds=10, ok=True, token=token)

    asyncio.run(make())


def test_a_local_podcast_and_video_report_one_rising_fraction(options_local):
    from neuralloop_books.engines.local import LocalEngine
    from neuralloop_books.models.fake import FakeModel
    from neuralloop_books.pipeline import run
    from neuralloop_books.speech.fake import FakeSpeech

    seen: list[tuple[str, float]] = []
    original = activity.Activity._report

    def spy(self, n, item, step, done, total, by, restart, fraction=None):
        if fraction is not None and item in ("audio", "video"):
            seen.append((item, fraction))
        return original(self, n, item, step, done, total, by, restart, fraction)

    activity.Activity._report = spy
    try:
        asyncio.run(run(options_local, LocalEngine.from_options(options_local, FakeModel(), FakeSpeech())))
    finally:
        activity.Activity._report = original
    for kind in ("audio", "video"):
        values = [f for k, f in seen if k == kind]
        assert (
            values and values == sorted(values) and values[-1] >= 0.9 and all(0 < f <= 1 for f in values)
        ), kind
