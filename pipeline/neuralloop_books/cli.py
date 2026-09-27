"""Command line: python nl_book.py BOOK [options]."""

import argparse
import asyncio
import os
import re
import sys
import webbrowser
from pathlib import Path

from .config import (
    AUDIO_FORMATS,
    DEFAULT_INSTRUCTIONS,
    LOCAL_PROVIDERS,
    PROVIDERS,
    SPEECH_ENGINES,
    VIDEO_FORMATS,
    VIDEO_STYLES,
)
from .models import SetupError, resolve_provider
from .pipeline import Options, run
from .state import FAILED, WAITING

SAMPLE_BOOK = Path(__file__).resolve().parent.parent / "sample" / "sample-book.epub"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="nl_book.py", description="A whole book in, a cute study site out.")
    parser.add_argument("book", nargs="?", help="a PDF or EPUB")
    parser.add_argument(
        "--chapters", default="all", help='which chapters, e.g. "1-5" or "1,3,7" (default all)'
    )
    parser.add_argument(
        "--media", default="1-3", help='chapters that also get a podcast + video (default "1-3")'
    )
    parser.add_argument("--audio", choices=[*AUDIO_FORMATS, "none"], default="deep-dive")
    parser.add_argument("--video", choices=[*VIDEO_FORMATS, "none"], default="explainer")
    parser.add_argument(
        "--style", choices=list(VIDEO_STYLES), default="kawaii", help="video look (kawaii matches Pip)"
    )
    parser.add_argument("--language", default="en")
    parser.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    parser.add_argument(
        "--parallel", type=int, help="items made at the same time (default 2; 1 for local models)"
    )
    parser.add_argument(
        "--engine",
        choices=["local", "notebooklm"],
        default="local",
        help="who makes the items (default local)",
    )
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        default="auto",
        help="text model for the local engine (auto: first key set)",
    )
    parser.add_argument("--model", help="model name for the provider (each has a sensible default)")
    parser.add_argument("--context", type=int, help="characters of chapter text sent at once")
    parser.add_argument(
        "--speech", choices=SPEECH_ENGINES, default="auto", help="voices for podcasts and explainers"
    )
    parser.add_argument("--voices", help='two voices, host A then host B, e.g. "Ira,Zoya"')
    parser.add_argument("--title")
    parser.add_argument("--out")
    parser.add_argument("--retry", action="store_true", help="retry failed and quota-limited items")
    parser.add_argument("--no-open", action="store_true", help="don't open the study site")
    parser.add_argument(
        "--dry-run", action="store_true", help="run everything offline with a practice model and voices"
    )
    args = parser.parse_args(argv)
    if args.dry_run and not args.book:
        args.book = str(SAMPLE_BOOK)
    if not args.book:
        parser.error("give a PDF or EPUB (or try --dry-run)")
    book = Path(args.book)
    if not book.exists():
        parser.error(f"file not found: {book}")
    if book.suffix.lower() not in (".pdf", ".epub"):
        parser.error("the book must be a PDF or an EPUB")
    args.out = args.out or f"neuralloop-{_slug(book.stem)}"
    if args.dry_run:
        args.engine, args.provider, args.speech = "local", "fake", "fake"
    return args


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60] or "book"


def _engine(opts: Options):
    if opts.engine == "notebooklm":
        try:
            import notebooklm
        except ImportError:
            sys.exit(
                'Install the NotebookLM library first: pip install "notebooklm-py[browser]" pypdf\n'
                "Then sign in once: notebooklm login"
            )
        from .engines.notebooklm import NotebookLMEngine
        from .notebook import open_client

        return NotebookLMEngine(asyncio.run(open_client(notebooklm.NotebookLMClient)), notebooklm, opts)
    from .engines.local import LocalEngine
    from .models import make_model
    from .speech import make_speech

    return LocalEngine.from_options(
        opts, make_model(opts.provider, opts.model), make_speech(opts.speech, opts.voices)
    )


def _default_parallel(args: argparse.Namespace) -> int:
    if args.parallel:
        return max(1, args.parallel)
    local = args.engine == "local" and (
        resolve_provider(args.provider, os.environ) in LOCAL_PROVIDERS or args.speech == "rumik"
    )
    return 1 if local else 2


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    opts = Options(
        book=Path(args.book),
        out=Path(args.out),
        chapters=args.chapters,
        media=args.media,
        audio=args.audio,
        video=args.video,
        style=args.style,
        language=args.language,
        instructions=args.instructions,
        parallel=_default_parallel(args),
        engine=args.engine,
        provider=args.provider,
        model=args.model,
        context=args.context,
        speech=args.speech,
        voices=args.voices,
        title=args.title,
        retry=args.retry,
        dry_run=args.dry_run,
    )
    try:
        engine = _engine(opts)
        if not args.no_open:
            opts.out.mkdir(parents=True, exist_ok=True)
        state = asyncio.run(run(opts, engine))
    except KeyboardInterrupt:
        print("\nPaused. Run the same command again to continue.")
        return 130
    except SetupError as error:
        print(error)
        return 3
    except ValueError as error:
        print(error)
        return 2
    except Exception as error:
        if any(k in f"{type(error).__name__} {error}".lower() for k in ("storage", "login", "auth")):
            print("You're not signed in to NotebookLM. Run: notebooklm login")
            return 3
        raise
    counts = state.counts()
    print("\nDone: " + ", ".join(f"{v} {k.replace('_', ' ')}" for k, v in sorted(counts.items())))
    if counts.get(WAITING):
        print(
            "Some items are waiting for the AI provider's limit. "
            "Run the same command again later to continue."
        )
    if counts.get(FAILED):
        print("Some items failed. Run again with --retry to try them again.")
    site_page = (opts.out / "index.html").resolve()
    print(f"Study site: {site_page}")
    if not args.no_open:
        webbrowser.open(site_page.as_uri())
    return 0
