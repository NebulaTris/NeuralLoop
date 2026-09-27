"""Browser tests for the study site. They drive the UI the way a person would.

Needs Playwright with Chromium (pip install playwright && python -m playwright install chromium)
and the site's dev dependencies (cd site && npm install). Skipped otherwise.
"""

import asyncio
import json
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")
SITE = Path(__file__).resolve().parents[2] / "site"
D3 = SITE / "node_modules" / "d3" / "dist" / "d3.min.js"
pytestmark = pytest.mark.skipif(not D3.exists(), reason="run `npm install` in site/ first")


@pytest.fixture(scope="module")
def site_dir(tmp_path_factory):
    from neuralloop_books.engines.notebooklm import NotebookLMEngine
    from neuralloop_books.fake_client import ENUMS, FakeClient
    from neuralloop_books.pipeline import Options, run
    from neuralloop_books.testing import LONG, write_epub

    root = tmp_path_factory.mktemp("book")
    book = write_epub(root / "book.epub", [("Caching", LONG), ("Queues", LONG)])
    opts = Options(book=book, out=root / "site", media="1-2", log=lambda _: None)
    asyncio.run(run(opts, NotebookLMEngine(FakeClient(delay=0), ENUMS, opts)))
    return root / "site"


@pytest.fixture
def page(site_dir):
    errors = []
    with playwright.sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 880})
        page.route("**/d3.min.js", lambda r: r.fulfill(path=str(D3), content_type="application/javascript"))
        page.route("**/fonts.googleapis.com/**", lambda r: r.fulfill(body="", content_type="text/css"))
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto((site_dir / "index.html").as_uri())
        page.wait_for_selector(".ch")
        yield page
        browser.close()
    assert errors == []


def finish_step(page):
    page.click("#fin")
    page.wait_for_timeout(100)


def close_loop(page, chapter):
    page.click('[data-go="home"]')
    page.click(f'[data-ch="{chapter}"]')
    finish_step(page)  # listen & watch
    finish_step(page)  # read
    while page.locator("#ans").count():  # recall in your own words
        page.fill("#ans", "The core trade-off matters when systems change; for example monitoring drift.")
        page.click("#chk")
        page.check('[data-kp="0"]')
        page.click("#scr")
        page.click("#nx")
    while page.locator(".opt").count():  # quiz
        page.click('.opt[data-o="0"]')
        page.click("#nb")
    page.click("#qdone")
    page.fill("#guess", "Foundations\n- key terms\nPractice")  # remake the map
    page.click("#cmp")
    page.click("#seefull")
    finish_step(page)
    while page.locator("#show").count():  # flashcards
        page.click("#show")
        page.click('[data-g="3"]')
    page.click("#dn")
    page.wait_for_selector(".modal")


def progress(page):
    return page.evaluate("JSON.parse(localStorage.getItem(Object.keys(localStorage)[0]))")


def test_chapter_two_starts_locked(page):
    assert page.locator(".ch.locked").count() == 1
    page.click('[data-ch="2"]', force=True)
    assert "Close chapter 1" in page.inner_text("#toast")


def test_listen_and_watch_share_one_page(page):
    page.click('[data-ch="1"]')
    assert page.locator("video").count() == 1 and page.locator("audio").count() == 1


def test_a_full_loop_unlocks_the_next_chapter(page):
    close_loop(page, 1)
    assert "Chapter 2" in page.inner_text(".modal") and "unlocked" in page.inner_text(".modal")
    page.click("#mnext")
    assert page.inner_text(".chapter-head h2") == "Queues"
    assert set(progress(page)["loop"]["1"]) >= {"prime", "read", "recall", "map", "space"}


def test_the_book_map_grows_and_keeps_earlier_ideas_in_place(page):
    page.click('[data-go="map"]')
    assert "tiny seed" in page.inner_text("#gm")
    close_loop(page, 1)
    page.click("#mok")
    page.click('[data-go="map"]')
    page.wait_for_timeout(4000)
    visible = "[...document.querySelectorAll('.node')].filter(n => n.style.display !== 'none').length"
    assert page.evaluate(visible) == 7
    first_idea = progress(page)["mapPos"]["c1:k0"]

    page.click('[data-go="home"]')
    page.click('[data-ch="2"]')
    page.click('[data-stage="map"]')
    page.fill("#guess", "Foundations")
    page.click("#cmp")
    page.click("#seefull")
    page.click('[data-go="map"]')
    page.wait_for_timeout(5500)
    assert page.evaluate(visible) == 14
    assert progress(page)["mapPos"]["c1:k0"] == first_idea
    assert "Chapter 2 · 7 ideas" in page.inner_text("#strip")


def test_review_only_includes_unlocked_chapters(page):
    page.click('[data-go="review"]')
    assert "card 1 of 3" in page.inner_text("#rv")


def test_book_data_contains_reading_text(site_dir):
    data = json.loads((site_dir / "book-data.js").read_text()[len("window.BOOK = ") :].rstrip(";\n"))
    assert data["chapters"][0]["read"]["kind"] == "text"
