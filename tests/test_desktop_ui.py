"""Browser tests for the desktop app's screens, with the Tauri backend simulated in the page.

Needs Playwright with Chromium and the study site's dev dependencies (cd pipeline/site && npm install).
"""

import asyncio
import functools
import shutil
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline"))
D3 = ROOT / "pipeline" / "site" / "node_modules" / "d3" / "dist" / "d3.min.js"
pytestmark = pytest.mark.skipif(not D3.exists(), reason="run `npm install` in pipeline/site first")

FAKE_TAURI = """
window.__NL_BASE__ = '/books/';
window.calls = [];
const listeners = {};
window.__TAURI__ = {
  core: { invoke: async (command, args) => {
    calls.push([command, args]);
    switch (command) {
      case 'list_books': return [
        { id: 'sample', title: 'Sample book', chapters: 2, loopsClosed: 0, running: false, ready: true, counts: { done: 12 }, due: 0 },
        { id: 'ddia', title: 'Designing Data-Intensive Applications', chapters: 12, loopsClosed: 0, running: true, ready: true, counts: { done: 9, waiting_quota: 2 }, due: 0 }];
      case 'check_setup': return { python: '/usr/bin/python3.12', notebooklm: '0.8.3', pypdf: '5.1.0', signedIn: false, samplePath: '/app/sample.epub' };
      case 'get_settings': return { python: '', nudges: true, quietStart: 22, quietEnd: 8, pausedUntil: 0 };
      case 'start_pipeline': return 'new-book';
      default: return null;
    }
  } },
  event: { listen: async (name, handler) => { (listeners[name] ||= []).push(handler); } },
  dialog: { open: async () => '/Users/me/Books/clean-code.pdf' },
  notification: { isPermissionGranted: async () => true, requestPermission: async () => 'granted', sendNotification: (n) => calls.push(['notify', n]) },
};
window.emit = (name, payload) => (listeners[name] || []).forEach((handler) => handler({ payload }));
"""


@pytest.fixture(scope="module")
def served(tmp_path_factory):
    from neuralloop_books.fake_client import ENUMS, FakeClient
    from neuralloop_books.pipeline import Options, run
    from neuralloop_books.testing import LONG, write_epub

    root = tmp_path_factory.mktemp("desktop")
    shutil.copytree(ROOT / "src", root, dirs_exist_ok=True)
    book = write_epub(root / "book.epub", [("Caching", LONG), ("Queues", LONG)])
    asyncio.run(run(Options(book=book, out=root / "books" / "sample", log=lambda _: None), FakeClient(delay=0), ENUMS))
    handler = functools.partial(SimpleHTTPRequestHandler, directory=str(root))
    handler.log_message = lambda *args: None
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


@pytest.fixture
def page(served):
    errors = []
    with playwright.sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 860})
        page.add_init_script(FAKE_TAURI)
        page.route("**/d3.min.js", lambda r: r.fulfill(path=str(D3), content_type="application/javascript"))
        page.route("**/fonts.googleapis.com/**", lambda r: r.fulfill(body="", content_type="text/css"))
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"{served}/index.html")
        page.wait_for_selector(".book")
        yield page
        browser.close()
    assert errors == []


def calls(page, name):
    return [args for command, args in page.evaluate("window.calls") if command == name]


def test_library_shows_books_setup_steps_and_pip(page):
    assert page.locator(".book").count() == 2
    assert "Preparing" in page.inner_text(".book >> nth=1")
    assert "notebooklm login" in page.inner_text(".setup")
    assert "preparing" in page.inner_text(".bubble").lower()


def test_adding_a_book_sends_the_chosen_options(page):
    page.click("#addbook")
    page.click('[data-style="watercolor"]')
    page.fill("#media", "1-3")
    page.click("#go")
    page.wait_for_timeout(200)
    opts = calls(page, "start_pipeline")[0]["opts"]
    assert (opts["path"], opts["media"], opts["style"], opts["dryRun"]) == ("/Users/me/Books/clean-code.pdf", "1-3", "watercolor", False)


def test_bad_chapter_ranges_are_caught_before_starting(page):
    page.click("#addbook")
    page.fill("#media", "1-")
    page.click("#go")
    assert not calls(page, "start_pipeline")
    assert "1-2" in page.inner_text("#toast")


def test_pipeline_output_appears_on_the_book_card(page):
    page.evaluate("emit('pipeline', { bookId: 'ddia', line: '  ✓ chapter 4 quiz (38s)' })")
    page.wait_for_timeout(300)
    assert "chapter 4 quiz" in page.inner_text(".book >> nth=1")


def test_settings_can_send_a_test_nudge(page):
    page.click('[data-nav="settings"]')
    page.wait_for_selector("#test")
    page.click("#test")
    assert calls(page, "notify")


def test_studying_inside_the_app_saves_progress(page):
    page.click('[data-open="sample"]')
    frame = page.frame_locator(".frame")
    frame.locator('[data-ch="1"]').click()
    frame.locator("#fin").click()
    page.wait_for_timeout(400)
    saved = calls(page, "save_progress")
    assert saved and saved[-1]["bookId"] == "sample" and "prime" in saved[-1]["data"]["loop"]["1"]
