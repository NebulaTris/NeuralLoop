"""Turn a narrated explainer into a real video: an animated HTML scene, rendered frame by frame, plus narration.

The scene is deterministic: `renderAt(t)` in the page draws exactly the frame for time t (slide text, bullet reveals,
captions, and Pip, whose CSS animations are pinned to t). Headless Chromium screenshots each frame and PyAV encodes
H.264 (the Mac's own VideoToolbox encoder; libx264 only where that can't start) with the narration as AAC. No ffmpeg install needed.
"""

import base64
import html
import io
import json
import re
from collections.abc import Callable
from fractions import Fraction
from pathlib import Path

from . import audio

ASSETS = Path(__file__).resolve().parent / "assets"
PIP_FILE = ASSETS / "pip-poses.js"
GAP = 0.6  # seconds between slides
FPS = 24
SIZE = (1280, 720)
FONTS = (
    ("Fredoka", 500, "fredoka-500.woff2"),
    ("Fredoka", 600, "fredoka-600.woff2"),
    ("Atkinson Hyperlegible", 400, "atkinson-400.woff2"),
    ("Atkinson Hyperlegible", 700, "atkinson-700.woff2"),
)


def timeline(durations: list[float], gap: float = GAP) -> list[tuple[float, float]]:
    """(start, end) of each slide, back to back with `gap` seconds between them."""
    spans, t = [], 0.0
    for d in durations:
        spans.append((round(t, 3), round(t + d, 3)))
        t += d + gap
    return spans


def total_length(spans: list[tuple[float, float]]) -> float:
    return spans[-1][1] if spans else 0.0


def _pip() -> tuple[dict, str]:
    text = PIP_FILE.read_text(encoding="utf-8")
    poses = json.loads(re.search(r"window\.PIP=(\{.*?\});\n", text, re.S).group(1))
    css = json.loads(re.search(r"window\.PIP_CSS=(\".*\");", text, re.S).group(1))
    return poses, css


def _fonts() -> str:
    faces = []
    for family, weight, file in FONTS:
        data = base64.b64encode((ASSETS / "fonts" / file).read_bytes()).decode()
        faces.append(
            f'@font-face{{font-family:"{family}";font-weight:{weight};src:url(data:font/woff2;base64,{data}) format("woff2")}}'
        )
    return "".join(faces)


def scene_html(
    title: str, slides: list[dict], spans: list[tuple[float, float]], size: tuple[int, int] = SIZE
) -> str:
    poses, pip_css = _pip()
    esc = html.escape
    width, height = size
    scale = width / 1280
    data = [
        {
            "start": start,
            "end": end,
            "points": len(s["points"]),
            "sentences": [x for x in re.split(r"(?<=[.!?])\s+", s["narration"].strip()) if x],
        }
        for s, (start, end) in zip(slides, spans, strict=True)
    ]
    slide_html = "".join(
        f'<section class="slide" id="s{i}"><div class="words"><p class="kicker">{esc(title)}</p>'
        f"<h1>{esc(s['title'])}</h1><ul>{''.join(f'<li>{esc(p)}</li>' for p in s['points'])}</ul></div>"
        f'<div class="pip moving">{poses.get(s["pose"], poses["read"])}</div>'
        f'<div class="captions">{"".join(f"<span>{esc(x)}</span>" for x in data[i]["sentences"])}</div></section>'
        for i, s in enumerate(slides)
    )
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
{_fonts()}
*{{box-sizing:border-box;margin:0;padding:0}}
html,body{{width:{width}px;height:{height}px;overflow:hidden;background:#FFF7F2}}
#stage{{position:absolute;inset:0;width:1280px;height:720px;transform:scale({scale});transform-origin:0 0;
  font-family:"Atkinson Hyperlegible",sans-serif;color:#35251F;background:#FFF7F2;overflow:hidden}}
.blob{{position:absolute;border-radius:50%;opacity:.55}}
#b1{{width:520px;height:520px;background:#FDE3D7;left:-120px;top:-160px}}
#b2{{width:420px;height:420px;background:#E3ECFF;right:-100px;bottom:-140px}}
#b3{{width:180px;height:180px;background:#FCEFCF;right:360px;top:60px}}
.slide{{position:absolute;inset:0;opacity:0}}
.words{{position:absolute;left:96px;top:120px;width:640px}}
.kicker{{font:600 20px "Fredoka",sans-serif;letter-spacing:.08em;text-transform:uppercase;color:#E0683F;opacity:0}}
h1{{font:600 60px/1.08 "Fredoka",sans-serif;margin-top:14px;opacity:0}}
ul{{list-style:none;margin-top:34px;display:grid;gap:18px}}
li{{font-size:30px;line-height:1.3;padding-left:44px;position:relative;opacity:0}}
li::before{{content:"";position:absolute;left:4px;top:.42em;width:18px;height:18px;border-radius:50%;background:#3FA88A}}
.pip{{position:absolute;right:110px;top:150px;width:340px}}
.captions{{position:absolute;left:96px;right:96px;bottom:70px;text-align:center}}
.captions span{{display:none;font-size:26px;line-height:1.35;background:#35251FE6;color:#FFF7F2;padding:10px 22px;border-radius:16px}}
#bar{{position:absolute;left:0;bottom:0;height:8px;background:#E0683F;width:0}}
#brand{{position:absolute;left:96px;bottom:26px;font:500 18px "Fredoka",sans-serif;color:#A08E86}}
{pip_css}
</style></head><body><div id="stage">
<div class="blob" id="b1"></div><div class="blob" id="b2"></div><div class="blob" id="b3"></div>
{slide_html}<div id="brand">NeuralLoop · Pip explains</div><div id="bar"></div></div>
<script>
const DATA = {_script_json(data)};
const TOTAL = {total_length(spans)};
const ease = x => 1 - Math.pow(1 - Math.min(Math.max(x, 0), 1), 3);
const springIn = x => x <= 0 ? 0 : 1 + Math.exp(-6 * x) * Math.sin(12 * x) * -0.12;
function renderAt(t) {{
  document.getAnimations().forEach(a => {{ a.pause(); a.currentTime = t * 1000; }});
  const b = document.getElementById.bind(document);
  // Background shapes drift in whole pixels, slowly: gentle motion that still compresses well.
  const drift = (a, r) => Math.round(Math.sin(t / a) * r);
  b("b1").style.transform = `translate(${{drift(9, 24)}}px, ${{drift(13, 18)}}px)`;
  b("b2").style.transform = `translate(${{drift(11, 22)}}px, ${{drift(15, 16)}}px)`;
  b("b3").style.transform = `translate(${{drift(7, 14)}}px, ${{drift(10, 10)}}px)`;
  b("bar").style.width = (100 * Math.min(t / TOTAL, 1)) + "%";
  DATA.forEach((s, i) => {{
    const el = b("s" + i), local = t - s.start, len = s.end - s.start;
    const fadeOut = i < DATA.length - 1 ? 1 - ease((t - s.end) / 0.4) : 1;
    const visible = local >= -0.3 && (i === DATA.length - 1 || t < s.end + 0.4);
    el.style.opacity = visible ? Math.min(ease((local + 0.3) / 0.5), fadeOut) : 0;
    if (!visible) return;
    const kick = el.querySelector(".kicker"), h = el.querySelector("h1");
    kick.style.opacity = ease(local / 0.5);
    h.style.opacity = ease((local - 0.1) / 0.5);
    h.style.transform = `translateY(${{(1 - ease((local - 0.1) / 0.6)) * 40}}px)`;
    el.querySelectorAll("li").forEach((li, j) => {{
      const at = 0.8 + j * (len * 0.6) / Math.max(s.points, 1);
      li.style.opacity = ease((local - at) / 0.4);
      li.style.transform = `translateX(${{(1 - ease((local - at) / 0.5)) * -30}}px)`;
    }});
    const pip = el.querySelector(".pip");
    pip.style.transform = `scale(${{springIn(local / 0.9)}}) translateY(${{Math.sin(t * 2.2) * 4}}px)`;
    const chars = s.sentences.map(x => x.length), all = chars.reduce((a, c) => a + c, 0);
    let spoken = Math.max(0, Math.min(local / len, 1)) * all, k = 0;
    while (k < chars.length - 1 && spoken > chars[k]) {{ spoken -= chars[k]; k++; }}
    el.querySelectorAll(".captions span").forEach((c, j) => c.style.display = j === k && local < len ? "inline-block" : "none");
  }});
}}
window.renderAt = renderAt;
</script></body></html>"""


def _script_json(value) -> str:
    """JSON that is safe inside <script>: narration saying "</script>" can't end the scene's code."""
    return json.dumps(value).replace("</", "<\\/")


def _decode_png(png: bytes, av):
    with av.open(io.BytesIO(png), format="png_pipe") as image:
        return next(image.decode(video=0))


# The Mac's own H.264 encoder (VideoToolbox, part of macOS) comes first. libx264, which PyAV's FFmpeg also carries
# (GPL-2.0-or-later; see NOTICE.md), is only a last resort for a machine where VideoToolbox can't start (Linux CI, a
# virtual Mac without a hardware encoder); MPEG-4 Part 2 is the final fallback.
ENCODERS = (
    ("h264_videotoolbox", {"b": "2000k"}),
    ("libx264", {"crf": "26", "preset": "veryfast", "tune": "animation"}),
    ("mpeg4", {"b": "2000k"}),
)


def _opens(av, name: str, options: dict, fps: int, size: tuple[int, int]) -> bool:
    """Whether this encoder exists and really starts here (VideoToolbox can be built in yet unavailable, as in a VM)."""
    try:
        probe = av.CodecContext.create(name, "w")
        probe.width, probe.height, probe.pix_fmt = size[0], size[1], "yuv420p"
        probe.time_base = Fraction(1, fps)
        probe.framerate = Fraction(fps, 1)
        probe.options = dict(options)
        probe.open()
    except (ValueError, av.error.FFmpegError):
        return False
    return True


def _encoder(av, container, fps: int, size: tuple[int, int]):
    for name, options in ENCODERS:
        if not _opens(av, name, options, fps, size):
            continue
        stream = container.add_stream(name, rate=fps, options=options)
        stream.width, stream.height, stream.pix_fmt = size[0], size[1], "yuv420p"
        return stream
    raise RuntimeError("no H.264 encoder available")


def render(
    out: Path,
    title: str,
    slides: list[dict],
    clips: list[Path],
    fps: int = FPS,
    size: tuple[int, int] = SIZE,
    progress: Callable[[int, int], None] | None = None,
) -> Path:
    """Render the explainer to `out` (.mp4). `clips` are each slide's narration WAV, in order. `progress(i, total)`
    hears about every tenth frame drawn."""
    import av
    from playwright.sync_api import sync_playwright

    narration = out.with_suffix(".narration.wav")
    try:
        lengths = audio.join_wavs(clips, narration, pause=GAP)
        spans = timeline(lengths)
        frames = int(total_length(spans) * fps) + 1
        page_html = scene_html(title, slides, spans, size)

        with av.open(str(out), "w") as container:
            video_stream = _encoder(av, container, fps, size)
            audio_stream = container.add_stream("aac", rate=24000)
            with sync_playwright() as p:
                browser = _browser(p)
                page = browser.new_page(viewport={"width": size[0], "height": size[1]})
                page.set_content(page_html)
                page.evaluate("document.fonts.ready")
                for i in range(frames):
                    if progress and i % 10 == 0:
                        progress(i, frames)
                    page.evaluate(f"renderAt({i / fps})")
                    frame = _decode_png(page.screenshot(type="png"), av).reformat(format="yuv420p")
                    # A decoded PNG is marked as an intra frame; left as is, every frame becomes a keyframe (huge files).
                    frame.pict_type = av.video.frame.PictureType.NONE
                    frame.pts, frame.time_base = i, Fraction(1, fps)
                    container.mux(video_stream.encode(frame))
                browser.close()
            container.mux(video_stream.encode())
            with av.open(str(narration)) as sound:
                for frame in sound.decode(audio=0):
                    frame.pts = None
                    container.mux(audio_stream.encode(frame))
            container.mux(audio_stream.encode())
    finally:
        narration.unlink(missing_ok=True)  # also when the browser or encoder fails
    return out


def _browser(p):
    """Playwright's Chromium, or the person's Google Chrome when Chromium isn't downloaded."""
    try:
        return p.chromium.launch()
    except Exception:  # Chromium not installed: Chrome works just as well for rendering
        return p.chromium.launch(channel="chrome")
