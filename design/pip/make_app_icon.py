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
IPAD = ROOT / "apple" / "App" / "iPad" / "Assets.xcassets" / "AppIcon.appiconset"  # the iPad's icon (one 1024 px image)
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
        # iPadOS icons are full-bleed squares with no transparency (the system rounds the corners): the same art,
        # scaled up so its rounded edge falls outside the square, on the icon's moss green.
        IPAD.mkdir(parents=True, exist_ok=True)
        page = browser.new_page(viewport={"width": 1024, "height": 1024})
        page.set_content(
            "<html><body style='margin:0;background:#3E7A62;overflow:hidden'>"
            f"<div style='width:1260px;height:1260px;margin:-118px'>{svg}</div></body></html>"
        )
        page.evaluate("document.querySelector('svg').setAttribute('width','100%');"
                      "document.querySelector('svg').setAttribute('height','100%')")
        page.screenshot(path=str(IPAD / "icon-1024.png"))
        browser.close()
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
        (IPAD / "Contents.json").write_text(
            '{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],'
            '"info":{"author":"xcode","version":1}}'
        )
        (IPAD.parent / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}')
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
