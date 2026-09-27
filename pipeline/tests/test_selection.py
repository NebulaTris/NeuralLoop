import pytest

from neuralloop_books.selection import parse_selection


def test_all_and_none():
    assert parse_selection("all", 3) == {1, 2, 3}
    assert parse_selection("none", 3) == set()


def test_ranges_and_lists_are_combined():
    assert parse_selection("1-2,5", 6) == {1, 2, 5}


def test_numbers_beyond_the_book_are_ignored():
    assert parse_selection("2-9", 4) == {2, 3, 4}


@pytest.mark.parametrize("bad", ["1-", "a", "3-1", "1,,2"])
def test_invalid_specs_raise_a_helpful_error(bad):
    with pytest.raises(ValueError):
        parse_selection(bad, 5)
