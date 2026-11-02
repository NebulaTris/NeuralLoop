"""Speech helpers: split text for a speech model, join WAV clips with pauses, convert to AAC."""

import array
import math
import re
import shutil
import subprocess
import wave
from pathlib import Path

from . import portable

# Rumik OSS-1 is trained on 30-second utterances; ~400 characters stays under that.
SPEECH_LIMIT = 400
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")
# Every clip is brought to the same loudness so the two hosts sound equally close.
TARGET_RMS = 0.1
MAX_PEAK = 0.95


def split_for_speech(text: str, limit: int = SPEECH_LIMIT) -> list[str]:
    """Pieces of at most `limit` characters, split at sentence ends (or words for giant sentences)."""
    pieces: list[str] = []
    current = ""
    for sentence in _SENTENCE_END.split(text.strip()):
        for part in _split_words(sentence, limit):
            candidate = f"{current} {part}" if current else part
            if len(candidate) <= limit:
                current = candidate
            else:
                pieces.append(current)
                current = part
    if current:
        pieces.append(current)
    return pieces


def _split_words(sentence: str, limit: int) -> list[str]:
    """A giant sentence split between words; a word longer than `limit` (a URL, a hash) is cut into pieces."""
    if len(sentence) <= limit:
        return [sentence]
    parts, current = [], ""
    for long_word in sentence.split():
        for word in (long_word[i : i + limit] for i in range(0, len(long_word), limit)):
            candidate = f"{current} {word}" if current else word
            if len(candidate) <= limit:
                current = candidate
            else:
                parts.append(current)
                current = word
    return [*parts, current] if current else parts


def duration(path: Path) -> float:
    with wave.open(str(path)) as clip:
        return clip.getnframes() / clip.getframerate()


def join_wavs(parts: list[Path], out: Path, pause: float = 0.35) -> list[float]:
    """Write the clips one after another with `pause` seconds of silence; return each clip's length."""
    durations: list[float] = []
    with wave.open(str(out), "wb") as joined:
        for i, part in enumerate(parts):
            with wave.open(str(part)) as clip:
                if i == 0:
                    joined.setparams(clip.getparams())
                    silence = b"\x00" * (
                        int(pause * clip.getframerate()) * clip.getsampwidth() * clip.getnchannels()
                    )
                else:
                    joined.writeframes(silence)
                joined.writeframes(_level(clip.readframes(clip.getnframes()), clip.getsampwidth()))
                durations.append(round(clip.getnframes() / clip.getframerate(), 3))
    return durations


def _level(frames: bytes, width: int) -> bytes:
    """Scale 16-bit audio to TARGET_RMS without clipping; other formats and silence pass through."""
    if width != 2 or not frames:
        return frames
    samples = array.array("h", frames)
    power = math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768
    peak = max(abs(s) for s in samples) / 32768
    if power == 0:
        return frames
    gain = min(TARGET_RMS / power, MAX_PEAK / peak)
    return array.array("h", (max(-32768, min(32767, round(s * gain))) for s in samples)).tobytes()


def to_m4a(wav: Path) -> Path:
    """AAC .m4a: macOS's built-in afconvert, else PyAV (Windows, Linux); with neither, keep the WAV."""
    target = wav.with_suffix(".m4a")
    afconvert = shutil.which("afconvert")
    if afconvert:
        subprocess.run(
            [afconvert, "-f", "m4af", "-d", "aac", str(wav), str(target)], check=True, capture_output=True
        )
    elif not _encode_aac(wav, target):
        return wav
    wav.unlink(missing_ok=True)
    return target


def _encode_aac(wav: Path, target: Path) -> bool:
    """WAV → AAC in an .m4a with PyAV's FFmpeg; False when PyAV isn't installed."""
    try:
        import av
    except ImportError:
        return False
    partial = target.with_name(target.name + ".part")
    with av.open(str(wav)) as source, av.open(str(partial), "w", format="ipod") as out:
        heard = source.streams.audio[0]
        stream = out.add_stream("aac", rate=heard.rate, layout="mono" if heard.channels == 1 else "stereo")
        stream.bit_rate = 96_000
        resampler = av.AudioResampler(format="fltp", layout=stream.layout, rate=heard.rate)
        for frame in source.decode(heard):
            for ready in resampler.resample(frame):
                out.mux(stream.encode(ready))
        for ready in resampler.resample(None):
            out.mux(stream.encode(ready))
        out.mux(stream.encode(None))
    portable.replace(partial, target)
    return True
