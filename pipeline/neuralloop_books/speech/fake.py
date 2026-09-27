"""Short tones instead of speech, for dry runs and tests."""

import math
import struct
import wave

RATE = 24_000


class FakeSpeech:
    name = "Pip's practice voice"
    voices = ("Tone A", "Tone B")

    def __init__(self):
        self.spoken: list[tuple[str, str]] = []

    def check(self) -> None:
        return None

    def synth(self, text: str, voice: str, delivery: str, path) -> None:
        self.spoken.append((voice, text))
        pitch = 440 if voice == self.voices[0] else 330
        frames = int(RATE * min(2.0, 0.2 + len(text) / 400))
        samples = (int(3000 * math.sin(2 * math.pi * pitch * i / RATE)) for i in range(frames))
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", s) for s in samples))
