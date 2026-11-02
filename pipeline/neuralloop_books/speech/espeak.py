"""Phonemes for Kokoro, from espeak-ng run as its own program.

espeak-ng is GPL-3.0, so NeuralLoop never loads its library: it runs the unmodified `espeak-ng` program
(bundled with the Windows app, installed on Linux) and reads what it prints. Kokoro expects espeak's IPA with
stress marks and the text's punctuation kept, so the punctuation is cut out here, each piece between the marks
is turned into phonemes, and the marks are put back where they were.

espeak-ng: https://github.com/espeak-ng/espeak-ng (see NOTICE.md).
"""

import os
import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

from .. import portable
from ..models import SetupError

# Marks kept for Kokoro. A point or comma between two digits belongs to a number ("3.14", "1,000").
_OTHER_MARKS = re.escape(';:!?¡¿—…"«»“”(){}[]')
_MARKS = re.compile(rf"(?:\s*(?:[{_OTHER_MARKS}]|(?<!\d)[.,]|[.,](?!\d))+\s*)+")
_LANGUAGE_FLAGS = re.compile(r"\([a-z]{2,3}(?:-[a-z0-9]+)?\)")  # "(fr)" where espeak switches language
TIMEOUT = 120

Runner = Callable[[str], str]


def split(text: str) -> list[tuple[str, bool]]:
    """The text as pieces in order: (words, False) and (a run of punctuation with its spaces, True)."""
    pieces: list[tuple[str, bool]] = []
    at = 0
    for match in _MARKS.finditer(text):
        if match.start() > at:
            pieces.append((text[at : match.start()], False))
        pieces.append((match.group(), True))
        at = match.end()
    if at < len(text):
        pieces.append((text[at:], False))
    return pieces


def program(env: dict | None = None) -> tuple[str, Path | None] | None:
    """espeak-ng and the folder holding its `espeak-ng-data` (None: its own default): NEURALLOOP_ESPEAK, then
    the copy inside the installed app, then one on PATH."""
    env = os.environ if env is None else env
    own = env.get("NEURALLOOP_ESPEAK")
    if own and Path(own).is_file():
        folder = Path(own).parent
        return own, folder if (folder / "espeak-ng-data").is_dir() else None
    if getattr(sys, "frozen", False):
        bundled = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent)) / "espeak-ng"
        for name in ("espeak-ng.exe", "espeak-ng"):
            if (bundled / name).is_file():
                return str(bundled / name), bundled
    found = shutil.which("espeak-ng")
    return (found, None) if found else None


class EspeakFailed(RuntimeError):
    """espeak-ng crashed or hung on some text: that podcast or video fails, nothing needs setting up."""


def require(env: dict | None = None) -> tuple[str, Path | None]:
    found = program(env)
    if found:
        return found
    if portable.WINDOWS:
        raise SetupError("Kokoro's voices need espeak-ng, which comes with NeuralLoop. Reinstall NeuralLoop.")
    raise SetupError(
        "Kokoro's voices need espeak-ng. Install it (for example `sudo apt install espeak-ng`) and try again."
    )


def command(exe: str, lang: str, data: Path | None) -> list[str]:
    """Quiet (no sound), IPA with stress marks, UTF-8 text from stdin."""
    argv = [exe, "-q", "--ipa", "-b", "1", "-v", lang]
    if data is not None:
        argv.append(f"--path={data}")
    return argv


def runner(lang: str = "en-us") -> Runner:
    exe, data = require()
    argv = command(exe, lang, data)

    def run(text: str) -> str:
        try:
            done = subprocess.run(
                argv, input=text.encode("utf-8"), capture_output=True, timeout=TIMEOUT, **portable.no_window()
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise EspeakFailed(f"espeak-ng didn't run ({error}).") from None
        if done.returncode != 0:
            problem = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["no message"]
            raise EspeakFailed(f"espeak-ng stopped (exit {done.returncode}: {problem[0]}).")
        return done.stdout.decode("utf-8", "replace")

    return run


def _groups(output: str) -> list[str]:
    """What espeak printed, one entry per piece: a blank line ends a piece; a piece espeak spread over several
    lines (a long clause) is joined back together."""
    groups: list[str] = []
    current: list[str] = []
    for line in output.replace("\r", "").split("\n"):
        if line.strip():
            current.append(line.strip())
        elif current:
            groups.append(" ".join(current))
            current = []
    if current:
        groups.append(" ".join(current))
    return groups


def phonemes_for(words: list[str], run: Runner) -> list[str]:
    """Each piece's phonemes: all in one run of espeak, separated by blank lines; if its answer doesn't line
    up one to one (a piece with no phonemes at all), each piece on its own."""
    clean = [" ".join(w.split()) for w in words]
    if len(clean) > 1:
        together = _groups(run("\n\n".join(clean) + "\n"))
        if len(together) == len(clean):
            return together
    return [" ".join(_groups(run(w + "\n"))) for w in clean]


def phonemize(text: str, lang: str = "en-us", run: Runner | None = None) -> str:
    """Text → Kokoro's phonemes: espeak's IPA with stress, the punctuation kept, spaces collapsed."""
    pieces = [(t, mark) for t, mark in split(text) if mark or t.strip()]
    words = [t for t, mark in pieces if not mark]
    said = iter(phonemes_for(words, run or runner(lang)) if words else [])
    out = []
    for piece, mark in pieces:
        out.append(piece if mark else _LANGUAGE_FLAGS.sub("", next(said, "")))
    return " ".join("".join(out).split())
