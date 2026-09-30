"""The app icons from design/pip/app-icon.svg: every size macOS wants, packed into
apple/App/Resources/AppIcon.icns, and the iPad's 1024 px icon
(apple/App/iPad/Assets.xcassets/AppIcon.appiconset/icon-1024.png).

Run `python design/pip/make_app_icon.py` from the repo root on a Mac (needs Playwright's Chromium, iconutil).
Never edit the icons by hand. It also writes design/pip/app-icon.input-sha256, a hash of what the icons are
made from (the SVG and this script); `--check` recomputes it without drawing anything and fails when the icons
are stale.
"""

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVG = ROOT / "design" / "pip" / "app-icon.svg"
OUT = ROOT / "apple" / "App" / "Resources" / "AppIcon.icns"
IPAD = (
    ROOT / "apple" / "App" / "iPad" / "Assets.xcassets" / "AppIcon.appiconset"
)  # the iPad's icon (one 1024 px image)
SIZES = (16, 32, 128, 256, 512)
STAMP = (
    ROOT / "design" / "pip" / "app-icon.input-sha256"
)  # hash of the inputs the committed icons were made from


def input_sha256() -> str:
    """SHA-256 of everything the icons are drawn from: the SVG and this script."""
    digest = hashlib.sha256()
    for path in (SVG, Path(__file__).resolve()):
        data = path.read_bytes()
        digest.update(f"{path.relative_to(ROOT)}\0{len(data)}\0".encode() + data)
    return digest.hexdigest()


def check() -> list[str]:
    problems = [f"{p.relative_to(ROOT)} is missing" for p in (OUT, IPAD / "icon-1024.png") if not p.is_file()]
    recorded = STAMP.read_text().strip() if STAMP.is_file() else ""
    if recorded != input_sha256():
        problems.append(f"{STAMP.relative_to(ROOT)} doesn't match app-icon.svg and make_app_icon.py")
    return problems


def main() -> None:
    if "--check" in sys.argv[1:]:
        problems = check()
        for problem in problems:
            print(f"✗ {problem}", file=sys.stderr)
        if problems:
            sys.exit(
                "The app icons are out of date: run `python design/pip/make_app_icon.py` on a Mac and commit."
            )
        print("The app icons are up to date.")
        return
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
                page.evaluate(
                    "document.querySelector('svg').setAttribute('width','100%');"
                    "document.querySelector('svg').setAttribute('height','100%')"
                )
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                page.screenshot(path=str(iconset / name), omit_background=True)
                page.close()
        # iPadOS icons are full-bleed squares with no transparency (the system rounds the corners): the same
        # art, scaled up so its rounded edge falls outside the square, on the icon's moss green.
        IPAD.mkdir(parents=True, exist_ok=True)
        page = browser.new_page(viewport={"width": 1024, "height": 1024})
        page.set_content(
            "<html><body style='margin:0;background:#3E7A62;overflow:hidden'>"
            f"<div style='width:1260px;height:1260px;margin:-118px'>{svg}</div></body></html>"
        )
        page.evaluate(
            "document.querySelector('svg').setAttribute('width','100%');"
            "document.querySelector('svg').setAttribute('height','100%')"
        )
        page.screenshot(path=str(IPAD / "icon-1024.png"))
        browser.close()
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
        (IPAD / "Contents.json").write_text(
            '{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],'
            '"info":{"author":"xcode","version":1}}'
        )
        (IPAD.parent / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}')
    STAMP.write_text(input_sha256() + "\n")
    for path in (OUT, IPAD / "icon-1024.png", STAMP):
        print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
