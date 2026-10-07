import importlib.util
import wave

import pytest

from neuralloop_books import video

SLIDES = [
    {
        "title": "Welcome <b>in</b>",
        "points": ["One", "Two"],
        "narration": "Hi! I'm Pip. Let's go.",
        "pose": "hop",
    },
    {"title": "The idea", "points": ["Drift"], "narration": "The world keeps moving.", "pose": "study"},
]


def test_the_timeline_places_slides_back_to_back_with_a_gap():
    spans = video.timeline([2.0, 3.0], gap=0.5)
    assert spans == [(0.0, 2.0), (2.5, 5.5)]
    assert video.total_length(spans) == 5.5


def test_the_scene_escapes_text_and_carries_every_slide():
    html = video.scene_html("Caching", SLIDES, video.timeline([2.0, 3.0]))
    assert "Welcome &lt;b&gt;in&lt;/b&gt;" in html and "<b>in</b>" not in html
    assert "The world keeps moving." in html and "renderAt" in html and "@font-face" in html


def write_tone(path, seconds):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(24000)
        out.writeframes(b"\x10\x00" * int(24000 * seconds))
    return path


needs_tools = pytest.mark.skipif(
    importlib.util.find_spec("av") is None or importlib.util.find_spec("playwright") is None,
    reason="video rendering needs PyAV and Playwright",
)


@needs_tools
def test_a_narrated_explainer_becomes_an_mp4_with_sound(tmp_path):
    import av

    clips = [write_tone(tmp_path / "a.wav", 1.0), write_tone(tmp_path / "b.wav", 1.0)]
    out = video.render(tmp_path / "explainer.mp4", "Caching", SLIDES, clips, fps=6, size=(320, 180))
    with av.open(str(out)) as container:
        kinds = {stream.type for stream in container.streams}
        seconds = container.duration / 1_000_000
    assert kinds == {"video", "audio"} and 2.3 < seconds < 3.2


@needs_tools
def test_frames_are_compressed_against_each_other_not_all_keyframes(tmp_path):
    import av

    clips = [write_tone(tmp_path / "a.wav", 2.0)]
    out = video.render(tmp_path / "e.mp4", "Caching", SLIDES[:1], clips, fps=12, size=(320, 180))
    with av.open(str(out)) as container:
        keys = [packet.is_keyframe for packet in container.demux(container.streams.video[0]) if packet.size]
    assert sum(keys) < len(keys) / 4


def test_narration_cannot_close_the_scene_script_early():
    slides = [{**SLIDES[0], "narration": "Never write </script><script>alert(1)</script> in a page."}]
    html = video.scene_html("Caching", slides, video.timeline([2.0]))
    assert html.count("</script>") == 1 and "<\\/script>" in html


def test_the_temporary_narration_is_removed_even_when_rendering_fails(tmp_path, monkeypatch):
    pytest.importorskip("av")
    pytest.importorskip("playwright")

    def broken(*args, **kwargs):
        raise RuntimeError("no browser")

    monkeypatch.setattr(video, "scene_html", broken)
    clips = [write_tone(tmp_path / "a.wav", 0.5)]
    with pytest.raises(RuntimeError):
        video.render(tmp_path / "e.mp4", "Caching", SLIDES[:1], clips, fps=6, size=(320, 180))
    assert not (tmp_path / "e.narration.wav").exists()


def test_the_macs_own_h264_encoder_comes_before_gpl_x264():
    names = [name for name, _ in video.ENCODERS]
    assert names[0] == "h264_videotoolbox"
    assert names.index("libx264") > names.index("h264_videotoolbox")


class FakeAV:
    """Just enough of PyAV for `_encoder`: encoders in `broken` exist but fail to open."""

    class error:
        class FFmpegError(Exception):
            pass

    def __init__(self, broken=()):
        av = self
        self.broken = set(broken)

        class Probe:
            def __init__(self, name):
                self.name = name

            def open(self):
                if self.name in av.broken:
                    raise av.error.FFmpegError("can't start")

        class CodecContext:
            @staticmethod
            def create(name, mode):
                return Probe(name)

        self.CodecContext = CodecContext


class FakeContainer:
    def __init__(self):
        self.added = []

    def add_stream(self, name, rate, options):
        self.added.append(name)
        return type("Stream", (), {})()


def test_videotoolbox_is_used_when_it_starts():
    container = FakeContainer()
    video._encoder(FakeAV(), container, 24, (320, 180))
    assert container.added == ["h264_videotoolbox"]


def test_x264_is_only_a_fallback_when_videotoolbox_cannot_start():
    container = FakeContainer()
    stream = video._encoder(FakeAV(broken={"h264_videotoolbox"}), container, 24, (320, 180))
    assert container.added == ["libx264"] and stream.pix_fmt == "yuv420p"
