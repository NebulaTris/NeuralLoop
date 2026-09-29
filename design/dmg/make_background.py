"""The picture behind the NeuralLoop disk image window: Pip asking to be dragged into Applications.

Run `python design/dmg/make_background.py` from the repo root (needs Playwright's Chromium, which `make setup` installs).
It writes design/dmg/background.tiff (1x and 2x in one file); scripts/package-mac.sh lays out the window with dmgbuild
using design/dmg/settings.py. Icon positions there must match APP and APPLICATIONS here. Never edit the TIFF by hand.
"""

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "design" / "pip"))
from generate_pip import CSS, POSES  # noqa: E402

WIDTH, HEIGHT = 660, 440
APP = (165, 238)  # centres of the two icons (settings.py uses the same numbers)
APPLICATIONS = (495, 238)
FONTS = ROOT / "pipeline" / "neuralloop_books" / "assets" / "fonts"


def font(family: str, weight: int, file: str) -> str:
    data = base64.b64encode((FONTS / file).read_bytes()).decode()
    return f"@font-face{{font-family:'{family}';font-weight:{weight};src:url(data:font/woff2;base64,{data}) format('woff2')}}"


def page() -> str:
    hop = POSES["hop"]()
    nap = POSES["read"]()
    ax, ay = APP
    bx, by = APPLICATIONS
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
{font("Fredoka", 600, "fredoka-600.woff2")}{font("Fredoka", 500, "fredoka-500.woff2")}{font("Atkinson", 400, "atkinson-400.woff2")}
{CSS}
html,body{{margin:0;width:{WIDTH}px;height:{HEIGHT}px;overflow:hidden}}
body{{background:#FFF7F2;font-family:Atkinson,sans-serif;color:#35251F;position:relative}}
.blob{{position:absolute;border-radius:50%;filter:blur(2px)}}
h1{{font-family:Fredoka;font-weight:600;font-size:30px;margin:0;position:absolute;top:26px;width:100%;text-align:center}}
.sub{{position:absolute;top:70px;width:100%;text-align:center;font-size:15px;color:#6E5A52}}
.slot{{position:absolute;width:150px;height:150px;border-radius:34px;background:rgba(255,255,255,.75);
       box-shadow:0 6px 24px rgba(224,104,63,.12);transform:translate(-50%,-50%)}}
.pip{{position:absolute}}
.note{{position:absolute;font-family:Fredoka;font-weight:500;color:#E0683F;font-size:17px}}
.note.small{{font-size:14px;color:#C0835F;transform:rotate(-3deg)}}
.fine{{position:absolute;bottom:18px;left:0;width:100%;text-align:center;font-size:12px;color:#A08E86;line-height:1.5}}
.fine b{{color:#6E5A52;font-weight:400}}
</style></head><body>
<div class="blob" style="width:260px;height:260px;left:-80px;top:-90px;background:#FDE3D7"></div>
<div class="blob" style="width:200px;height:200px;right:-60px;top:-50px;background:#FCEFCF"></div>
<div class="blob" style="width:220px;height:220px;right:-70px;bottom:-110px;background:#DDF3EA"></div>
<div class="blob" style="width:160px;height:160px;left:-50px;bottom:-80px;background:#E3ECFF"></div>
<h1>Hi! I'm Pip. Let's move in together!</h1>
<div class="sub">Drag me into your Applications folder. No boxes, no heavy lifting, I already packed my yarn.</div>
<div class="slot" style="left:{ax}px;top:{ay}px"></div>
<div class="slot" style="left:{bx}px;top:{by}px"></div>
<svg width="{WIDTH}" height="{HEIGHT}" style="position:absolute;left:0;top:0">
  <path d="M {ax + 88} {ay - 10} C {ax + 150} {ay - 95}, {bx - 150} {by - 95}, {bx - 90} {by - 12}"
        fill="none" stroke="#E0683F" stroke-width="4" stroke-linecap="round" stroke-dasharray="2 11"/>
  <path d="M {bx - 104} {by - 30} L {bx - 88} {by - 10} L {bx - 112} {by - 6}"
        fill="none" stroke="#E0683F" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
  {"".join(paw(x, y, r) for x, y, r in ((ax + 118, ay - 58, -30), (ax + 150, ay - 80, -15), (bx - 150, by - 82, 15)))}
</svg>
<div class="note" style="left:{(ax + bx) // 2 - 22}px;top:{ay - 108}px">whee!</div>
<div class="note small" style="left:{ax - 40}px;top:{ay + 84}px">that's me!</div>
<div class="note small" style="left:{bx - 52}px;top:{by + 84}px">my new room ✨</div>
<div class="pip" style="left:{(ax + bx) // 2 - 45}px;top:{ay - 58}px;width:90px">{hop}</div>
<div class="pip" style="left:22px;top:{HEIGHT - 150}px;width:82px;transform:rotate(-6deg)">{nap}</div>
<div class="fine">Then open NeuralLoop from Applications. The first time, macOS double-checks with you:<br>
<b>System Settings → Privacy &amp; Security → Open Anyway.</b> It's just being careful. I'm very well behaved.</div>
</body></html>"""


def paw(x: float, y: float, rotate: float) -> str:
    toes = "".join(f'<circle cx="{dx}" cy="{dy}" r="2.6"/>' for dx, dy in ((-6, -7), (-2, -10), (3, -10), (7, -7)))
    return f'<g transform="translate({x} {y}) rotate({rotate})" fill="#F2B6A0"><ellipse cx="0" cy="0" rx="6" ry="5"/>{toes}</g>'


def main() -> None:
    from playwright.sync_api import sync_playwright

    out = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory() as tmp, sync_playwright() as p:
        browser = p.chromium.launch()
        shots = []
        for scale in (1, 2):
            view = browser.new_page(viewport={"width": WIDTH, "height": HEIGHT}, device_scale_factor=scale)
            view.set_content(page(), wait_until="load")
            view.evaluate("document.fonts.ready")
            shot = Path(tmp) / f"background@{scale}x.png"
            view.screenshot(path=str(shot))
            shots.append(shot)
        browser.close()
        # One TIFF with both sizes: Finder picks the sharp one on Retina screens.
        subprocess.run(["tiffutil", "-cathidpicheck", *map(str, shots), "-out", str(out / "background.tiff")], check=True)
    print("wrote design/dmg/background.tiff")


if __name__ == "__main__":
    main()
