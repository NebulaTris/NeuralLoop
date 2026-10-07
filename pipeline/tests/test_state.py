from neuralloop_books.state import DONE, FAILED, SKIPPED, TODO, WAITING, BookState


def make_state(tmp_path, chapters=3):
    return BookState.create(
        tmp_path / "state.json",
        title="T",
        source="t.pdf",
        chapters=[{"n": n, "title": f"C{n}", "file": f"{n:02d}.pdf"} for n in range(1, chapters + 1)],
        dry_run=False,
    )


def statuses(state, task):
    return [c["tasks"][task]["status"] for c in state.chapters]


def test_saving_reaches_the_disk_before_the_file_is_swapped_in(tmp_path, monkeypatch):
    import os

    events = []
    real_fsync, real_replace = os.fsync, os.replace
    monkeypatch.setattr(os, "fsync", lambda fd: (events.append("fsync"), real_fsync(fd))[1])
    monkeypatch.setattr(os, "replace", lambda a, b: (events.append("replace"), real_replace(a, b))[1])
    make_state(tmp_path)
    assert events[:2] == ["fsync", "replace"] and (tmp_path / "state.json").exists()


def test_an_unreadable_state_file_is_reported_not_returned(tmp_path):
    import pytest

    from neuralloop_books.state import UnreadableState

    for text in ('{"chapters": [', "[]", '{"title": "no chapters"}'):
        (tmp_path / "state.json").write_text(text)
        with pytest.raises(UnreadableState):
            BookState.load(tmp_path / "state.json")


def test_a_state_file_with_the_wrong_shape_inside_is_reported_not_returned(tmp_path):
    """JSON that parses but isn't a book's state would crash every run (KeyError) and never be kept aside."""
    import json

    import pytest

    from neuralloop_books.state import UnreadableState

    good = {"n": 1, "title": "C1", "file": "01.md", "sourceId": None, "tasks": {"quiz": {"status": "todo"}}}
    shapes = [
        {"title": "T", "source": "t", "chapters": [{"n": 1}]},
        {"title": "T", "source": "t", "chapters": ["chapter one"]},
        {"title": "T", "source": "t", "chapters": [{**good, "n": "1"}]},
        {"title": "T", "source": "t", "chapters": [{**good, "file": None}]},
        {"title": "T", "source": "t", "chapters": [{**good, "tasks": []}]},
        {"title": "T", "source": "t", "chapters": [{**good, "tasks": {"quiz": "done"}}]},
        {"title": "T", "source": "t", "chapters": [{**good, "tasks": {"quiz": {}}}]},
        {"source": "t", "chapters": [good]},
        {"title": "T", "source": 3, "chapters": [good]},
    ]
    for shape in shapes:
        (tmp_path / "state.json").write_text(json.dumps(shape))
        with pytest.raises(UnreadableState):
            BookState.load(tmp_path / "state.json")
    (tmp_path / "state.json").write_text(json.dumps({"title": "T", "source": "t", "chapters": [good]}))
    assert BookState.load(tmp_path / "state.json").chapters[0]["n"] == 1


def test_a_run_keeps_a_wrongly_shaped_state_aside_and_starts_afresh(epub, tmp_path):
    import asyncio
    import json

    from neuralloop_books.engines.local import LocalEngine
    from neuralloop_books.models.fake import FakeModel
    from neuralloop_books.pipeline import Options, run
    from neuralloop_books.speech.fake import FakeSpeech

    opts = Options(book=epub, out=tmp_path / "o", media="none", log=lambda _: None)
    opts.out.mkdir()
    (opts.out / "state.json").write_text(json.dumps({"title": "T", "source": "t", "chapters": [{"n": 1}]}))
    state = asyncio.run(run(opts, LocalEngine.from_options(opts, FakeModel(), FakeSpeech())))
    assert state.chapters[0]["tasks"]["quiz"]["status"] == DONE
    assert list(opts.out.glob("state.json.unreadable-*"))


def test_media_only_for_selected_chapters(tmp_path):
    state = make_state(tmp_path)
    state.apply_selection({1, 2, 3}, {1}, audio=True, video=True, retry=False)
    assert statuses(state, "video") == [TODO, SKIPPED, SKIPPED]
    assert statuses(state, "quiz") == [TODO, TODO, TODO]


def test_widening_the_selection_revives_skipped_items_but_keeps_finished_ones(tmp_path):
    state = make_state(tmp_path)
    state.apply_selection({1, 2, 3}, {1}, audio=True, video=True, retry=False)
    state.chapters[0]["tasks"]["video"]["status"] = DONE
    state.apply_selection({1, 2, 3}, {1, 2}, audio=True, video=True, retry=False)
    assert statuses(state, "video") == [DONE, TODO, SKIPPED]


def test_retry_only_revives_failed_and_waiting(tmp_path):
    state = make_state(tmp_path, 2)
    state.chapters[0]["tasks"]["quiz"]["status"] = FAILED
    state.chapters[1]["tasks"]["quiz"]["status"] = WAITING
    state.chapters[1]["tasks"]["cards"]["status"] = DONE
    state.apply_selection({1, 2}, set(), audio=True, video=True, retry=False)
    assert statuses(state, "quiz") == [FAILED, TODO] and statuses(state, "cards") == [TODO, DONE]
    state.apply_selection({1, 2}, set(), audio=True, video=True, retry=True)
    assert statuses(state, "quiz") == [TODO, TODO]


def test_pending_finishes_chapters_in_reading_order(tmp_path):
    state = make_state(tmp_path, 2)
    state.apply_selection({1, 2}, {1, 2}, audio=True, video=True, retry=False)
    order = [(c["n"], t) for c, t in state.pending()]
    assert order[:5] == [(1, "study"), (1, "graph"), (1, "quiz"), (1, "cards"), (1, "mindmap")]
    assert order.index((1, "audio")) < order.index((2, "study"))


def test_old_states_gain_new_tasks_and_survive_reload(tmp_path):
    state = make_state(tmp_path, 1)
    del state.chapters[0]["tasks"]["study"]
    state.save()
    reloaded = BookState.load(tmp_path / "state.json")
    reloaded.ensure_tasks()
    assert reloaded.chapters[0]["tasks"]["study"] == {"status": TODO}


def test_items_left_working_by_an_interrupted_run_are_picked_up_again(tmp_path):
    state = make_state(tmp_path, 1)
    state.chapters[0]["tasks"]["quiz"]["status"] = "working"
    assert state.reset_interrupted() == 1
    assert state.chapters[0]["tasks"]["quiz"]["status"] == "todo"


def test_a_normal_run_tries_items_waiting_for_a_limit_again_but_not_failed_ones(tmp_path):
    state = make_state(tmp_path, 2)
    state.chapters[0]["tasks"]["quiz"]["status"] = FAILED
    state.chapters[1]["tasks"]["quiz"]["status"] = WAITING
    state.apply_selection({1, 2}, set(), audio=True, video=True, retry=False)
    assert statuses(state, "quiz") == [FAILED, TODO]
