"""macOS's built-in voices through `say`: always there, no downloads, no license limits."""

import subprocess

from ..models import SetupError

RATE = 24_000
PREFERRED = ("Samantha", "Daniel", "Karen", "Moira", "Tessa", "Alex", "Fred")


class SaySpeech:
    name = "macOS voices"

    def __init__(self, voices: tuple[str, str] | None, executable: str | None):
        self.executable = executable
        self._chosen = voices
        self.voices = voices or ("Samantha", "Daniel")

    def check(self) -> None:
        if not self.executable:
            raise SetupError(
                "The macOS `say` voices aren't available on this computer. Choose another speech engine."
            )
        if self._chosen is None:
            listing = subprocess.run([self.executable, "-v", "?"], capture_output=True, text=True).stdout
            installed = {line.split()[0] for line in listing.splitlines() if line.strip()}
            picks = [v for v in PREFERRED if v in installed]
            if len(picks) >= 2:
                self.voices = (picks[0], picks[1])

    def synth(self, text: str, voice: str, delivery: str, path) -> None:
        # `say` can't do vocalisations; drop tags like <laugh>.
        spoken = text.replace("<laugh>", "").replace("<chuckle>", "").replace("<sigh>", "")
        subprocess.run(
            [
                self.executable,
                "-v",
                voice,
                "-o",
                str(path),
                "--file-format=WAVE",
                f"--data-format=LEI16@{RATE}",
                spoken,
            ],
            check=True,
            capture_output=True,
        )
