"""The few places where macOS/Linux (POSIX) and Windows differ, kept in one module.

- The book's run lock: `flock` on POSIX, `msvcrt.locking` on Windows. Both are released by the operating
  system when the process ends, even when it's killed, so a left-over `.running` file never blocks.
- Children that must outlive a stop, or be stopped together with everything they start: a new session on
  POSIX, a new process group on Windows (and never a console window popping up from the windowless app).
- Ending a process tree: SIGTERM then SIGKILL to the group on POSIX; `taskkill /T`, then `/F`, on Windows
  (System32's own taskkill, by its full path).
- Programs NeuralLoop may run: never a `.cmd` or `.bat` launcher on Windows (cmd.exe reads their arguments
  again).
- How much memory the machine has (to pick a local model that fits).
- Where the person's NeuralLoop folder is, and whether Google Chrome is installed (for Google sign-in).
"""

import contextlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import IO

WINDOWS = sys.platform == "win32"
# What copy calls the person's computer ("your Mac's AI", "your PC's AI").
MACHINE = "PC" if WINDOWS else "Mac"

APP_ID = "app.neuralloop.books"
WINDOWS_APP_FOLDER = "NeuralLoop"

# Windows process creation flags (spelled out so this module imports the same everywhere).
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000

# On Windows the lock is one byte far past the pid the file holds, so writing the pid never touches it.
_WINDOWS_LOCK_OFFSET = 1 << 30


class LockBusy(Exception):
    """Another process holds the lock."""


def try_lock(handle: IO) -> None:
    """Take an exclusive lock on an open file without waiting, or raise `LockBusy`."""
    if WINDOWS:
        import msvcrt

        handle.seek(_WINDOWS_LOCK_OFFSET)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            raise LockBusy from None
        finally:
            handle.seek(0)
        return
    import fcntl

    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise LockBusy from None


def unlock(handle: IO) -> None:
    """Let go of a lock taken with `try_lock` (Windows wants it unlocked before the file closes)."""
    if WINDOWS:
        import msvcrt

        handle.seek(_WINDOWS_LOCK_OFFSET)
        with contextlib.suppress(OSError):
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        handle.seek(0)
        return
    import fcntl

    with contextlib.suppress(OSError):
        fcntl.flock(handle, fcntl.LOCK_UN)


def is_locked(path: Path) -> bool:
    """Whether another process holds the lock on this file (a left-over file nobody holds is not locked)."""
    try:
        handle = open(path, "rb")  # noqa: SIM115 - closed below
    except OSError:
        return False
    try:
        try_lock(handle)
    except LockBusy:
        return True
    finally:
        with contextlib.suppress(OSError):
            unlock(handle)
        handle.close()
    return False


def replace(
    source: str | os.PathLike, target: str | os.PathLike, tries: int = 40, wait: float = 0.05
) -> None:
    """`os.replace`, waiting out a moment when another process has the target open: Windows refuses to
    replace an open file (the app reading book.json while the pipeline writes it), and the reader lets go
    within a moment. After about two seconds the error stands. Elsewhere a permission error is a real one."""
    if not WINDOWS:
        os.replace(source, target)
        return
    for attempt in range(tries):
        try:
            os.replace(source, target)
            return
        except PermissionError:
            if attempt == tries - 1:
                raise
            time.sleep(wait)


def is_script_launcher(path: str | os.PathLike) -> bool:
    """Whether running `path` would go through cmd.exe, which parses its arguments again by its own rules
    (a `.cmd` or `.bat` file, the kind npm puts on PATH). NeuralLoop never runs one."""
    return WINDOWS and Path(path).suffix.lower() in (".cmd", ".bat")


def taskkill() -> str:
    """Windows' own taskkill, by its full path: never whatever a `taskkill` on PATH might be."""
    return str(Path(os.environ.get("SYSTEMROOT") or r"C:\Windows") / "System32" / "taskkill.exe")


def no_window() -> dict:
    """Popen arguments so a command-line child never opens a console window on Windows."""
    return {"creationflags": CREATE_NO_WINDOW} if WINDOWS else {}


def own_group() -> dict:
    """Popen arguments for a child in its own session/group (so it can outlive us, or be ended as a tree)."""
    if WINDOWS:
        return {"creationflags": CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW}
    return {"start_new_session": True}


# Started by PowerShell, which exits at once: the program is left with no living parent, so ending the run's
# tree (taskkill /T follows parent ids) never reaches it. Program and arguments come from the environment.
_DETACH = (
    "Start-Process -WindowStyle Hidden -FilePath $env:NEURALLOOP_DETACHED_PROGRAM "
    "-ArgumentList $env:NEURALLOOP_DETACHED_ARGUMENTS"
)


def spawn_detached(argv: list[str], env: dict[str, str]) -> None:
    """Start a program that keeps running after this one stops, and after the run is stopped (Ollama)."""
    if not WINDOWS:
        subprocess.Popen(
            argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True
        )
        return
    powershell = Path(os.environ.get("SYSTEMROOT") or r"C:\Windows") / "System32" / "WindowsPowerShell"
    launcher = subprocess.Popen(
        [str(powershell / "v1.0" / "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command", _DETACH],
        env={
            **env,
            "NEURALLOOP_DETACHED_PROGRAM": argv[0],
            "NEURALLOOP_DETACHED_ARGUMENTS": " ".join(argv[1:]),  # fixed words ("serve"), never text
        },
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
    )
    with contextlib.suppress(subprocess.TimeoutExpired):
        launcher.wait(30)


def end_tree(process: subprocess.Popen, wait: float = 5) -> None:
    """End a process and everything it started: politely, then for good after `wait` seconds."""
    if WINDOWS:
        for force in (False, True):
            argv = [taskkill(), "/T", *(["/F"] if force else []), "/PID", str(process.pid)]
            with contextlib.suppress(OSError):
                subprocess.run(argv, capture_output=True, **no_window())
            try:
                process.wait(wait)
                return
            except subprocess.TimeoutExpired:
                continue
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, sig)
        try:
            process.wait(wait)
            break
        except subprocess.TimeoutExpired:
            continue
    with contextlib.suppress(ProcessLookupError, PermissionError):  # anything the group left behind
        os.killpg(process.pid, signal.SIGKILL)


def _windows_memory() -> int:
    import ctypes

    class MemoryStatus(ctypes.Structure):
        _fields_ = [
            ("dwLength", ctypes.c_ulong),
            ("dwMemoryLoad", ctypes.c_ulong),
            ("ullTotalPhys", ctypes.c_ulonglong),
            ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong),
            ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong),
            ("ullAvailVirtual", ctypes.c_ulonglong),
            ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    status = MemoryStatus()
    status.dwLength = ctypes.sizeof(MemoryStatus)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
    return int(status.ullTotalPhys)


def total_memory() -> int:
    """Physical memory in bytes."""
    if WINDOWS:
        return _windows_memory()
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")


def app_data(env: dict | None = None) -> Path:
    """The person's NeuralLoop folder (books, ai.json, browsers): the same one the app uses.

    macOS `~/Library/Application Support/app.neuralloop.books`, Windows `%LOCALAPPDATA%\\NeuralLoop` (books
    and media get big: never in the roaming profile), Linux `$XDG_DATA_HOME/app.neuralloop.books`
    (`~/.local/share/…`).
    """
    env = os.environ if env is None else env
    if env.get("NEURALLOOP_HOME"):  # the app's own override (tests, a second library)
        return Path(env["NEURALLOOP_HOME"])
    if WINDOWS:
        base = env.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / WINDOWS_APP_FOLDER
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_ID
    return Path(env.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / APP_ID


def chrome_paths(env: dict | None = None) -> list[Path]:
    """Where Google Chrome lives when it's installed."""
    env = os.environ if env is None else env
    if WINDOWS:
        roots = [env.get(name) for name in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA")]
        return [Path(root) / "Google" / "Chrome" / "Application" / "chrome.exe" for root in roots if root]
    if sys.platform == "darwin":
        return [Path("/Applications/Google Chrome.app")]
    return [
        Path(p)
        for p in ("/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/opt/google/chrome/chrome")
    ]


def chrome_installed() -> bool:
    return any(path.exists() for path in chrome_paths())
