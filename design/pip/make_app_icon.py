"""The Mac app's icon from design/pip/app-icon.svg: every size macOS wants, packed into apple/App/Resources/AppIcon.icns.

Run `python design/pip/make_app_icon.py` from the repo root (needs Playwright's Chromium). Never edit the .icns by hand.
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVG = ROOT / "design" / "pip" / "app-icon.svg"
OUT = ROOT / "apple" / "App" / "Resources" / "AppIcon.icns"
SIZES = (16, 32, 128, 256, 512)


def main() -> None:
    from playwright.sync_api import sync_playwright

    svg = SVG.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as tmp, sync_playwright() as p:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        browser = p.chromium.launch()
        for size in SIZES:
            for scale in (1, 2):
                page = browser.new_page(viewport={"width": size, "height": size}, device_scale_factor=scale)
                page.set_content(
                    "<html><body style='margin:0;background:transparent'>"
                    f"<div style='width:{size}px;height:{size}px'>{svg}</div></body></html>"
                )
                page.evaluate("document.querySelector('svg').setAttribute('width','100%');"
                              "document.querySelector('svg').setAttribute('height','100%')")
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                page.screenshot(path=str(iconset / name), omit_background=True)
                page.close()
        browser.close()
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
        shutil.copy(iconset / "icon_512x512@2x.png", Path(tmp) / "preview.png")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
