"""Command line: python nl_book.py BOOK [options]."""

import argparse
import asyncio
import dataclasses
import json
import os
import re
import sys
from pathlib import Path

from . import aiconfig
from .chapters import UnreadableBookError, UnsafeBookError
from .config import (
    AUDIO_FORMATS,
    AUDIO_LENGTHS,
    DEFAULT_INSTRUCTIONS,
    LOCAL_PROVIDERS,
    PROVIDERS,
    SPEECH_ENGINES,
    VIDEO_FORMATS,
    VIDEO_STYLES,
)
from .models import SetupError, resolve_provider, safe_message
from .pipeline import BookProblem, Options, run
from .state import FAILED, WAITING

SAMPLE_BOOK = Path(__file__).resolve().parent.parent / "sample" / "sample-book.epub"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="nl_book.py", description="A whole book in, learning loops for the NeuralLoop app out."
    )
    parser.add_argument("book", nargs="?", help="a PDF or EPUB")
    parser.add_argument(
        "--chapters", default="all", help='which chapters, e.g. "1-5" or "1,3,7" (default all)'
    )
    parser.add_argument(
        "--media", default="1-3", help='chapters that also get a podcast + video (default "1-3")'
    )
    parser.add_argument("--audio", choices=[*AUDIO_FORMATS, "none"], default="deep-dive")
    parser.add_argument(
        "--audio-length", choices=AUDIO_LENGTHS, help="podcast length (default from ai.json, else auto)"
    )
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
        choices=["auto", "local", "notebooklm"],
        help="who makes the items (auto: NotebookLM, and your local AI whenever it can't)",
    )
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        help="text model for the local engine (auto: first key set)",
    )
    parser.add_argument("--model", help="model name for the provider (each has a sensible default)")
    parser.add_argument("--context", type=int, help="characters of chapter text sent at once")
    parser.add_argument(
        "--speech", choices=SPEECH_ENGINES, default="auto", help="voices for podcasts and explainers"
    )
    parser.add_argument("--voices", help='two voices, host A then host B, e.g. "Ira,Zoya"')
    parser.add_argument("--base-url", help="address of an OpenAI-compatible service (with --provider custom)")
    parser.add_argument(
        "--setup", action="store_true", help="first run: start Ollama, download the local model and Rumik"
    )
    parser.add_argument("--signin", action="store_true", help="sign in with Google (used for NotebookLM)")
    parser.add_argument("--account", action="store_true", help="print the signed-in Google account as JSON")
    parser.add_argument("--signout", action="store_true", help="forget the saved Google sign-in")
    parser.add_argument(
        "--usage", action="store_true", help="NotebookLM's remaining usage and reset times, as JSON"
    )
    parser.add_argument(
        "--check-ai", action="store_true", help="test every model in ai.json (Settings → Save and test)"
    )
    parser.add_argument(
        "--grade-recall",
        action="store_true",
        help="check a recall answer: JSON {question, keyPoints, answer} on stdin",
    )
    parser.add_argument("--ai-config", help="this person's AI choices (ai.json from Settings)")
    parser.add_argument("--title")
    parser.add_argument("--out")
    parser.add_argument(
        "--retry", action="store_true", help="retry failed items (items waiting for a limit always are)"
    )
    parser.add_argument(
        "--no-open", action="store_true", help="(does nothing; kept so older callers still work)"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="run everything offline with a practice model and voices"
    )
    args = parser.parse_args(argv)
    args.config = aiconfig.load(Path(args.ai_config) if args.ai_config else None)
    if args.grade_recall:
        return args
    # Flags win over the person's ai.json, which wins over built-in defaults.
    args.engine = args.engine or args.config.engine
    if args.provider is None:
        args.provider, args.model = args.config.make.provider, args.model or args.config.make.model
        args.base_url = args.base_url or args.config.make.base_url
    args.voices = args.voices or ",".join(args.config.voices)
    if args.setup or args.signin or args.account or args.signout or args.check_ai or args.usage:
        return args
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
        # Offline and free: nothing from ai.json may reach a real model (or a real key).
        args.engine, args.provider, args.speech = "local", "fake", "fake"
        args.model = args.base_url = None
        args.config = dataclasses.replace(
            args.config, make=aiconfig.ModelChoice("fake"), tasks={}, recall=aiconfig.ModelChoice("fake")
        )
    return args


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60] or "book"


def _notebooklm_engine(opts: Options):
    try:
        import notebooklm
    except ImportError as error:
        raise SetupError("NotebookLM isn't installed") from error
    from .engines.notebooklm import NotebookLMEngine
    from .notebook import open_client

    return NotebookLMEngine(
        None, notebooklm, opts, open_client=lambda: open_client(notebooklm.NotebookLMClient)
    )


def _local_engine(opts: Options):
    from .engines.local import LocalEngine
    from .models import make_model
    from .speech import make_speech

    env = {**os.environ, **({"NEURALLOOP_BASE_URL": opts.base_url} if opts.base_url else {})}
    choices = [opts.provider, *(c.provider for c in opts.task_choices.values())]
    before_start = None
    if any(resolve_provider(p, env) == "ollama" for p in choices):
        from . import setup

        async def before_start() -> None:  # awaited by the engine, inside whatever loop is running
            await setup.ensure_ollama(setup.ollama_host(), opts.log)

    model = make_model(opts.provider, opts.model, env, allow_agent_tools=opts.hermes_tools)
    task_models = {task: _model_for(choice, opts.hermes_tools) for task, choice in opts.task_choices.items()}
    speech = make_speech(opts.speech, opts.voices, opts.voice_quality)
    return LocalEngine.from_options(opts, model, speech, task_models, before_start=before_start)


def _model_for(choice: aiconfig.ModelChoice, hermes_tools: bool = False):
    from .models import make_model

    env = {**os.environ, **({"NEURALLOOP_BASE_URL": choice.base_url} if choice.base_url else {})}
    return make_model(choice.provider, choice.model, env, allow_agent_tools=hermes_tools)


async def _check_ai(config: aiconfig.AIConfig) -> dict:
    """Try each configured model: a setup check, then a tiny request. Keys come from the environment."""
    import time

    roles = {
        "make": config.make,
        **{f"task:{t}": c for t, c in config.tasks.items()},
        "recall": config.recall,
    }

    async def one(choice: aiconfig.ModelChoice) -> dict:
        started = time.monotonic()
        try:
            model = _model_for(choice, config.hermes_tools)
            await model.check()
            await asyncio.wait_for(
                model.complete("check", "Reply with JSON only.", "", 'Reply with {"ok": true}'), 90
            )
        except Exception as error:  # every failure becomes a message for Settings, never a crash
            return {
                "ok": False,
                "provider": choice.provider,
                "message": safe_message(str(error).strip().splitlines()[0] if str(error).strip() else "")
                or type(error).__name__,
            }
        return {
            "ok": True,
            "provider": getattr(model, "provider", choice.provider),
            "name": model.name,
            "model": model.model or "",
            "seconds": round(time.monotonic() - started, 1),
        }

    results = await asyncio.gather(*(one(choice) for choice in roles.values()))
    return dict(zip(roles, results, strict=True))


def _grade_recall(args: argparse.Namespace) -> int:
    from . import recall

    request = json.loads(sys.stdin.read() or "{}")
    choice = args.config.recall
    if args.provider:
        choice = aiconfig.ModelChoice(args.provider, args.model, args.base_url)
    try:
        model = _model_for(choice, args.config.hermes_tools)
    except SetupError:
        model = None  # no grader available: word matching still answers
    if model is None:
        model = _Unavailable()
    result = asyncio.run(
        recall.grade(
            model,
            str(request.get("question", "")),
            list(request.get("keyPoints", [])),
            str(request.get("answer", "")),
        )
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


class _Unavailable:
    name = "word match"

    async def complete(self, *args):
        raise OSError("no grader configured")


def _engine(opts: Options):
    if opts.engine == "notebooklm":
        try:
            import notebooklm  # noqa: F401
        except ImportError:
            sys.exit(
                'Install the NotebookLM library first: pip install "notebooklm-py[browser]" pypdf\n'
                "Then sign in once: python nl_book.py --signin"
            )
        return _notebooklm_engine(opts)
    if opts.engine == "local":
        return _local_engine(opts)
    from .engines.auto import AutoEngine

    return AutoEngine(lambda: _notebooklm_engine(opts), lambda: _local_engine(opts), opts.log)


# NotebookLM's own words for a missing or expired sign-in (not just any error that mentions "author").
_SIGNED_OUT = re.compile(
    r"\bnot (?:signed|logged) in\b|\bnotebooklm login\b|\bstorage[_ ]state\b|\bunauthenticated\b"
    r"|\b(?:sign|log) ?in (?:again|first)\b|\bsession (?:has )?expired\b",
    re.IGNORECASE,
)


def _is_signed_out(error: BaseException) -> bool:
    from .notebook import is_auth_error

    names = {cls.__name__ for cls in type(error).__mro__}
    if names & {"AuthError", "AuthenticationError", "NotAuthenticatedError"} or is_auth_error(error):
        return True
    return bool(_SIGNED_OUT.search(str(error)))


def _signin() -> int:
    """Sign in with Google in a real browser window; the same session is what NotebookLM uses."""
    from . import account

    return account.sign_in(print)


def _default_parallel(args: argparse.Namespace) -> int:
    if args.parallel:
        return max(1, args.parallel)
    local = args.engine in ("auto", "local") and (
        resolve_provider(args.provider, os.environ) in LOCAL_PROVIDERS
    )
    return 1 if local else 2


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.grade_recall:
        return _grade_recall(args)
    if args.signin:
        return _signin()
    if args.signout:
        from . import account

        return account.sign_out()
    if args.usage:
        from . import account

        print("NotebookLM usage: " + json.dumps(account.usage()))
        return 0
    if args.check_ai:
        report = asyncio.run(_check_ai(args.config))
        print("AI check: " + json.dumps(report, ensure_ascii=False))
        return 0 if all(r["ok"] for r in report.values()) else 3
    if args.account:
        from . import account

        now = account.status()
        print("Account: " + json.dumps(now))
        return 0 if now["signedIn"] else 3
    if args.setup:
        from . import setup

        try:
            asyncio.run(
                setup.run_setup(
                    print,
                    args.model,
                    recall_model=args.config.recall,
                    voice_quality=args.config.voice_quality,
                )
            )
        except SetupError as error:
            print(safe_message(error, 1000))
            return 3
        return 0
    opts = Options(
        book=Path(args.book),
        out=Path(args.out),
        chapters=args.chapters,
        media=args.media,
        audio=args.audio,
        audio_length=args.audio_length or args.config.audio_length,
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
        base_url=args.base_url,
        task_choices=dict(args.config.tasks),
        hermes_tools=args.config.hermes_tools,
        voice_quality=args.config.voice_quality,
        title=args.title,
        retry=args.retry,
        dry_run=args.dry_run,
    )
    try:
        engine = _engine(opts)
        state = asyncio.run(run(opts, engine))
    except KeyboardInterrupt:
        print("\nPaused. Run the same command again to continue.")
        return 130
    except SetupError as error:
        print(safe_message(error, 1000))
        return 3
    except (BookProblem, UnreadableBookError, UnsafeBookError) as error:
        print(safe_message(error, 1000))
        return 2
    except Exception as error:
        if _is_signed_out(error):
            print("You're not signed in to NotebookLM. Run: notebooklm login")
            return 3
        raise
    counts = state.counts()
    print("\nDone: " + ", ".join(f"{v} {k.replace('_', ' ')}" for k, v in sorted(counts.items())))
    if counts.get(WAITING):
        print(
            "Some items are waiting for the AI provider's limit. "
            "Run the same command again once it resets, and Pip will pick them up."
        )
    if counts.get(FAILED):
        print("Some items failed. Run again with --retry to try them again.")
    print(f"Book: {opts.out.resolve()}")
    return 0
