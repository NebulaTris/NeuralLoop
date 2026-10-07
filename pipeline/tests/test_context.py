import asyncio

from neuralloop_books import context
from neuralloop_books.models.fake import FakeModel


def test_short_text_is_one_chunk():
    assert context.chunks("One.\n\nTwo.", budget=100) == ["One.\n\nTwo."]


def test_long_text_splits_on_paragraphs_within_budget_and_loses_nothing():
    paragraphs = [f"Paragraph {i} " + "x" * 50 for i in range(30)]
    text = "\n\n".join(paragraphs)
    pieces = context.chunks(text, budget=200)
    assert len(pieces) > 1 and all(len(p) <= 200 for p in pieces)
    assert "\n\n".join(pieces) == text


def test_a_giant_paragraph_is_cut_to_fit():
    pieces = context.chunks("y" * 1000, budget=300)
    assert all(len(p) <= 300 for p in pieces) and "".join(pieces) == "y" * 1000


def test_no_piece_is_empty_even_with_blank_paragraphs_or_a_budget_too_small():
    text = "a" * 50 + "\n\n\n\n\n\n" + "b" * 50 + "\n\n" + "c" * 120
    pieces = context.chunks(text, budget=50)
    assert pieces and all(pieces) and all(len(p) <= 50 for p in pieces)
    assert "".join(pieces).replace("\n", "") == "a" * 50 + "b" * 50 + "c" * 120
    assert all(context.chunks("xyz", budget=b) for b in (0, -5))  # never a crash or an endless loop


def test_source_fits_as_is(tmp_path):
    model = FakeModel()
    text = asyncio.run(
        context.source_for(model, "Short chapter.", budget=1000, cache=tmp_path / "notes.json")
    )
    assert text == "Short chapter." and model.calls == []


def test_long_source_is_condensed_once_and_cached(tmp_path):
    model = FakeModel()
    long_text = "\n\n".join("Idea " + "z" * 90 for _ in range(20))
    cache = tmp_path / "notes.json"
    first = asyncio.run(context.source_for(model, long_text, budget=500, cache=cache))
    calls = len(model.calls)
    assert calls > 1 and all(kind == "condense" for kind, *_ in model.calls)
    assert "Notes" in first and cache.exists()
    again = asyncio.run(context.source_for(model, long_text, budget=500, cache=cache))
    assert again == first and len(model.calls) == calls


def test_notes_made_for_a_bigger_budget_are_remade_for_a_smaller_one(tmp_path):
    import json

    model = FakeModel()
    long_text = "\n\n".join("Idea " + "z" * 90 for _ in range(40))
    cache = tmp_path / "notes.json"
    asyncio.run(context.source_for(model, long_text, budget=2_000, cache=cache))
    assert json.loads(cache.read_text())["budget"] == 2_000
    cache.write_text(json.dumps({"notes": "n" * 1_500, "budget": 2_000}))  # fits 2,000, not 1,000
    calls = len(model.calls)
    notes = asyncio.run(context.source_for(model, long_text, budget=1_000, cache=cache))
    assert len(model.calls) > calls and notes != "n" * 1_500
    assert json.loads(cache.read_text())["budget"] == 1_000
    calls = len(model.calls)
    again = asyncio.run(context.source_for(model, long_text, budget=2_000, cache=cache))
    assert again == notes and len(model.calls) == calls  # shorter notes still fit a bigger budget
