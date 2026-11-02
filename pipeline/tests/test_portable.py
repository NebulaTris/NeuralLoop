"""The operating-system differences (POSIX and Windows): the book's lock, process trees, memory, folders."""

import subprocess
import sys
import types
from pathlib import Path

import pytest

from neuralloop_books import portable


def test_lock_is_exclusive_between_handles(tmp_path):
    path = tmp_path / ".running"
    first = open(path, "a+")  # noqa: SIM115
    second = open(path, "a+")  # noqa: SIM115
    try:
        portable.try_lock(first)
        with pytest.raises(portable.LockBusy):  # a second open file is refused, even in the same process
            portable.try_lock(second)
    finally:
        first.close()
        second.close()


def test_lock_is_released_when_the_handle_closes(tmp_path):
    path = tmp_path / ".running"
    with open(path, "a+") as first:
        portable.try_lock(first)
    with open(path, "a+") as again:
        portable.try_lock(again)


def test_another_holder_shows_as_locked_and_a_left_over_file_does_not(tmp_path):
    path = tmp_path / ".running"
    assert not portable.is_locked(path)  # no file at all
    held = subprocess.Popen(
        [sys.executable, "-c", HOLD, str(path)],
        stdout=subprocess.PIPE,
        text=True,
        cwd=Path(__file__).parents[1],
    )
    try:
        assert held.stdout.readline().strip() == "locked"
        assert portable.is_locked(path)
    finally:
        held.kill()
        held.wait()
    assert path.exists() and not portable.is_locked(path)


HOLD = """
import sys, time
from neuralloop_books import portable
handle = open(sys.argv[1], "a+")
portable.try_lock(handle)
print("locked", flush=True)
time.sleep(60)
"""


class FakeMsvcrt(types.ModuleType):
    LK_NBLCK = 2
    LK_UNLCK = 0

    def __init__(self, busy: bool):
        super().__init__("msvcrt")
        self.busy = busy
        self.calls: list[tuple[int, int, int]] = []

    def locking(self, fd: int, mode: int, size: int) -> None:
        if self.busy:
            raise OSError(36, "Resource deadlock avoided")
        self.calls.append((fd, mode, size))


def test_windows_locks_one_byte_far_past_the_pid(tmp_path, monkeypatch):
    fake = FakeMsvcrt(busy=False)
    monkeypatch.setitem(sys.modules, "msvcrt", fake)
    monkeypatch.setattr(portable, "WINDOWS", True)
    with open(tmp_path / ".running", "a+") as handle:
        portable.try_lock(handle)
        assert fake.calls == [(handle.fileno(), fake.LK_NBLCK, 1)]
        assert handle.tell() == 0  # writing the pid starts at the beginning again


def test_windows_lock_held_elsewhere_is_busy(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, "msvcrt", FakeMsvcrt(busy=True))
    monkeypatch.setattr(portable, "WINDOWS", True)
    with open(tmp_path / ".running", "a+") as handle, pytest.raises(portable.LockBusy):
        portable.try_lock(handle)


def test_background_children_get_their_own_group(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", False)
    assert portable.own_group() == {"start_new_session": True}
    assert portable.no_window() == {}
    monkeypatch.setattr(portable, "WINDOWS", True)
    flags = portable.own_group()["creationflags"]
    assert flags & portable.CREATE_NEW_PROCESS_GROUP
    assert flags & portable.CREATE_NO_WINDOW
    assert portable.no_window() == {"creationflags": portable.CREATE_NO_WINDOW}


def test_end_tree_on_windows_asks_taskkill_politely_then_firmly(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", True)
    ran: list[list[str]] = []
    monkeypatch.setattr(portable.subprocess, "run", lambda argv, **kw: ran.append(argv))

    class Stubborn:
        pid = 4242

        def __init__(self):
            self.waits = 0

        def wait(self, timeout=None):
            self.waits += 1
            if self.waits == 1:
                raise subprocess.TimeoutExpired("x", timeout)
            return 0

    monkeypatch.setenv("SYSTEMROOT", r"C:\Windows")
    portable.end_tree(Stubborn(), wait=0)
    taskkill = str(Path(r"C:\Windows") / "System32" / "taskkill.exe")  # never one found on PATH
    assert ran[0] == [taskkill, "/T", "/PID", "4242"]
    assert ran[1] == [taskkill, "/T", "/F", "/PID", "4242"]


def test_end_tree_on_posix_ends_the_group():
    process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], **portable.own_group())
    portable.end_tree(process, wait=5)
    assert process.poll() is not None


def test_total_memory_is_plausible():
    assert 256 * 1024**2 < portable.total_memory() < 64 * 1024**4


def test_windows_memory_comes_from_the_kernel(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", True)
    monkeypatch.setattr(portable, "_windows_memory", lambda: 16 * 1024**3)
    assert portable.total_memory() == 16 * 1024**3


def test_windows_app_data_is_under_local_appdata(monkeypatch):
    """Books and media get big: they belong in the local folder, never the roaming profile."""
    monkeypatch.setattr(portable, "WINDOWS", True)
    folder = portable.app_data(
        {"APPDATA": "C:/Users/pip/AppData/Roaming", "LOCALAPPDATA": "C:/Users/pip/AppData/Local"}
    )
    assert folder.parts[-1] == "NeuralLoop" and "Local" in folder.parts


def test_windows_chrome_is_looked_for_in_program_files(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", True)
    paths = portable.chrome_paths(
        {"PROGRAMFILES": "C:/Program Files", "LOCALAPPDATA": "C:/Users/pip/AppData/Local"}
    )
    assert [p.name for p in paths] == ["chrome.exe", "chrome.exe"]
    assert "Program Files" in paths[0].parts


def test_the_apps_home_override_wins_everywhere(monkeypatch):
    for windows in (True, False):
        monkeypatch.setattr(portable, "WINDOWS", windows)
        assert portable.app_data({"NEURALLOOP_HOME": "/tmp/nl", "APPDATA": "C:/x"}).as_posix() == "/tmp/nl"


def test_replace_waits_out_a_reader_on_windows(tmp_path, monkeypatch):
    """Windows refuses to replace a file someone has open; the reader lets go in a moment."""
    monkeypatch.setattr(portable, "WINDOWS", True)
    source, target = tmp_path / "a.tmp", tmp_path / "a.json"
    source.write_text("new")
    target.write_text("old")
    real = portable.os.replace
    refusals = []

    def busy_then_free(a, b):
        if len(refusals) < 3:
            refusals.append(1)
            raise PermissionError(13, "Access is denied")
        real(a, b)

    monkeypatch.setattr(portable.os, "replace", busy_then_free)
    monkeypatch.setattr(portable.time, "sleep", lambda s: None)
    portable.replace(source, target)
    assert target.read_text() == "new" and len(refusals) == 3


def test_replace_gives_up_on_a_file_that_stays_locked(tmp_path, monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", True)

    def always_busy(a, b):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(portable.os, "replace", always_busy)
    monkeypatch.setattr(portable.time, "sleep", lambda s: None)
    with pytest.raises(PermissionError):
        portable.replace(tmp_path / "a", tmp_path / "b")


def test_replace_never_retries_off_windows(tmp_path, monkeypatch):
    """On a Mac or Linux a permission error is a real one: it fails at once."""
    monkeypatch.setattr(portable, "WINDOWS", False)
    tries = []

    def refused(a, b):
        tries.append(1)
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(portable.os, "replace", refused)
    monkeypatch.setattr(portable.time, "sleep", lambda s: pytest.fail("waited"))
    with pytest.raises(PermissionError):
        portable.replace(tmp_path / "a", tmp_path / "b")
    assert tries == [1]


@pytest.mark.parametrize("name", ["opencode.cmd", "HERMES.BAT", "tool.Cmd"])
def test_windows_refuses_script_launchers(monkeypatch, name):
    """cmd.exe reads a .cmd or .bat file's arguments again, by its own rules: never run one with ours."""
    monkeypatch.setattr(portable, "WINDOWS", True)
    assert portable.is_script_launcher(f"C:/tools/{name}")
    monkeypatch.setattr(portable, "WINDOWS", False)
    assert not portable.is_script_launcher(f"/usr/bin/{name}")


def test_windows_programs_are_fine(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", True)
    assert not portable.is_script_launcher("C:/tools/opencode.exe")
    assert not portable.is_script_launcher("C:/tools/hermes")


def test_a_detached_program_outlives_the_run_on_posix(monkeypatch):
    monkeypatch.setattr(portable, "WINDOWS", False)
    seen = []
    monkeypatch.setattr(portable.subprocess, "Popen", lambda argv, **kw: seen.append((argv, kw)))
    portable.spawn_detached(["/usr/bin/ollama", "serve"], {"PATH": "/usr/bin"})
    argv, kwargs = seen[0]
    assert argv == ["/usr/bin/ollama", "serve"] and kwargs["start_new_session"] is True
    assert kwargs["env"] == {"PATH": "/usr/bin"}


def test_a_detached_program_on_windows_is_never_part_of_the_runs_tree(monkeypatch):
    """Stopping a run ends its whole tree (taskkill /T follows parents): Ollama is started by a PowerShell
    that exits at once, so it has no living parent in the run's tree. Its path rides in the environment,
    never on a command line."""
    monkeypatch.setattr(portable, "WINDOWS", True)
    monkeypatch.setenv("SYSTEMROOT", r"C:\Windows")
    seen = []

    class Done:
        def wait(self, timeout=None):
            return 0

    monkeypatch.setattr(portable.subprocess, "Popen", lambda argv, **kw: seen.append((argv, kw)) or Done())
    program = r"C:\Users\pip\AppData\Local\Programs\Ollama\ollama.exe"
    portable.spawn_detached([program, "serve"], {"SYSTEMROOT": r"C:\Windows"})
    argv, kwargs = seen[0]
    assert argv[0] == str(Path(r"C:\Windows") / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")
    assert program not in " ".join(argv) and "Start-Process" in argv[-1]
    assert kwargs["env"]["NEURALLOOP_DETACHED_PROGRAM"] == program
    assert kwargs["env"]["NEURALLOOP_DETACHED_ARGUMENTS"] == "serve"
    assert kwargs["env"]["SYSTEMROOT"] == r"C:\Windows"
    assert kwargs["creationflags"] & portable.CREATE_NO_WINDOW
