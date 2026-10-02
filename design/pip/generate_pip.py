"""Pip the red panda: the single source of truth for Pip's artwork and animation.

Run `python design/pip/generate_pip.py` from the repo root to regenerate (`--force` redraws every PNG;
`--check` writes nothing and fails when the committed files are out of date, without a browser):
  - apple/App/Resources/pip-rig.json                 (the Mac and iPad apps: layers, pivots, keyframes)
  - apple/App/Resources/PipLayers/*.png              (every layer as a transparent 3x bitmap, plus the menu-bar icon)
  - pipeline/neuralloop_books/assets/pip-poses.js   (explainer videos)
Never edit those files by hand. See docs/specs/03-pip-design-system.md.
"""

import hashlib
import json
import math
from pathlib import Path

OUT = "#3B2A26"
FUR = "#CF5F39"
FUR2 = "#E4855A"
DARK = "#4B302A"
CREAM = "#FFF4E6"
RING = "#F2B48E"
PINK = "#F29AA6"
EYE = "#2A1D1B"
MOUTH = "#B8424F"


def yarn(x, y, r, wound=False):
    s = [
        f'<circle cx="{x}" cy="{y}" r="{r}" fill="#6F8FE8" stroke="{OUT}" stroke-width="3"/>',
        f'<path d="M{x - r * 0.8},{y - r * 0.3} Q{x},{y + r * 0.35} {x + r * 0.85},{y - r * 0.4} M{x - r * 0.9},{y + r * 0.25} Q{x},{y + r * 0.9} {x + r * 0.8},{y + r * 0.3} M{x - r * 0.35},{y - r * 0.9} Q{x + r * 0.1},{y} {x - r * 0.1},{y + r * 0.95}" fill="none" stroke="#FFFFFF" stroke-width="2.4" opacity=".75"/>',
    ]
    if not wound:
        s.append(
            f'<path d="M{x + r * 0.7},{y + r * 0.7} Q{x + r * 1.6},{y + r * 1.3} {x + r * 2.4},{y + r * 0.9}" fill="none" stroke="#6F8FE8" stroke-width="3" stroke-linecap="round"/>'
        )
    return "".join(s)


def svg(inner, w=240, h=220, label="Pip"):
    return f'<svg viewBox="0 0 {w} {h}" width="100%" height="100%" role="img" aria-label="{label}" style="display: block">{inner}</svg>'


def icon_head(expr="open"):
    return f'<svg viewBox="-62 -66 124 118" width="100%" height="100%" role="img" aria-label="Pip menu bar icon" style="display: block">{head(0, 0, 1, expr)}</svg>'


def mono_head(col):
    return f'<svg viewBox="-62 -66 124 118" width="100%" height="100%" role="img" aria-label="Pip template icon" style="display: block"><g fill="{col}"><path d="M-48,-6 C-62,-40 -48,-60 -22,-45 C-30,-30 -36,-16 -48,-6 Z"/><path d="M48,-6 C62,-40 48,-60 22,-45 C30,-30 36,-16 48,-6 Z"/><ellipse cx="0" cy="0" rx="50" ry="42"/></g><g fill="{("#FFFFFF" if col != "#FFFFFF" else "#1E2230")}"><ellipse cx="-21" cy="-2" rx="8" ry="9.5"/><ellipse cx="21" cy="-2" rx="8" ry="9.5"/><path d="M-6,12 Q0,8 6,12 Q0,19 -6,12 Z"/></g></svg>'


SHADE = "#A9472A"
IRIS = "#6A3A2B"


def fluffy(rx, ry, tufts, depth, step=9):
    pts = []
    n = int(360 / step)
    for i in range(n):
        a = math.radians(i * step)
        r_push = 0
        deg = i * step
        for lo, hi in tufts:
            if lo <= deg <= hi and i % 2 == 0:
                r_push = depth
        k = 1 + r_push / max(rx, ry)
        pts.append((rx * math.cos(a) * k, ry * math.sin(a) * k))

    def mid(p, q):
        return ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)

    m0 = mid(pts[-1], pts[0])
    d = f"M{m0[0]:.1f},{m0[1]:.1f}"
    for i, p in enumerate(pts):
        m = mid(p, pts[(i + 1) % n])
        d += f" Q{p[0]:.1f},{p[1]:.1f} {m[0]:.1f},{m[1]:.1f}"
    return d + " Z"


HEAD_D = fluffy(51, 43, [(18, 70), (110, 162)], 9)
CHEEK_L = fluffy(16, 14, [(100, 250)], 5, step=15)


def ear(side, droop=False):
    if droop:  # a floppy ear for sad Pip: hangs from the top of the head down to the eyes, cream side showing
        return (
            f'<g transform="scale({side},1)"><path d="M-24,-40 C-48,-50 -74,-28 -70,0 C-62,-2 -52,-10 -42,-20 Z" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/>'
            f'<path d="M-31,-35 C-48,-41 -64,-25 -62,-7 C-56,-9 -49,-16 -41,-24 Z" fill="{CREAM}"/>'
            f'<path d="M-50,-24 L-58,-14 M-45,-29 L-55,-22" fill="none" stroke="{RING}" stroke-width="2" stroke-linecap="round"/></g>'
        )
    return f'<g transform="scale({side},1)"><path d="M-48,-6 C-63,-42 -48,-62 -21,-46 C-30,-30 -36,-16 -48,-6 Z" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><path d="M-43,-13 C-53,-37 -44,-50 -28,-42 C-33,-31 -37,-22 -43,-13 Z" fill="{CREAM}"/><path d="M-40,-18 L-44,-30 M-36,-20 L-37,-34" stroke="{RING}" stroke-width="2" stroke-linecap="round"/></g>'


def eyes(expr):
    if expr == "shock":  # wide white eyes with tiny pupils, brows shot up
        s = "".join(
            f'<ellipse cx="{x}" cy="-3" rx="11" ry="12.5" fill="#FFFFFF" stroke="{EYE}" stroke-width="2.6"/><circle cx="{x}" cy="-2" r="4" fill="{EYE}"/><circle cx="{x + 1.5}" cy="-3.5" r="1.3" fill="#FFFFFF"/>'
            for x in (-21, 21)
        )
        return (
            s
            + f'<path d="M-31,-22 Q-21,-29 -11,-23 M11,-23 Q21,-29 31,-22" fill="none" stroke="{OUT}" stroke-width="3" stroke-linecap="round"/>'
        )
    if expr == "sad":  # big wet eyes, brows tipped up in the middle, and one tear on its way down
        s = eyes("open").replace('r="3.9"', 'r="4.8"')
        s += f'<path d="M-31,-14 Q-23,-16 -13,-22 M13,-22 Q23,-16 31,-14" fill="none" stroke="{OUT}" stroke-width="3" stroke-linecap="round"/>'
        s += '<path d="M-31,7 Q-21,11 -11,7 M11,7 Q21,11 31,7" fill="none" stroke="#7FB8F0" stroke-width="2.4" stroke-linecap="round" opacity=".9"/>'
        return (
            s
            + '<g class="tear"><path d="M-27,10 Q-31,17 -27,20 Q-23,17 -27,10 Z" fill="#8CC4F5" stroke="#4E8FD0" stroke-width="1.4"/></g>'
        )
    if expr in ("open", "proud"):
        s = ""
        for x in (-21, 21):
            s += f'<ellipse cx="{x}" cy="-2" rx="9" ry="10.5" fill="{EYE}"/><ellipse cx="{x}" cy="2.5" rx="6.2" ry="5" fill="{IRIS}" opacity=".9"/><circle cx="{x + 3}" cy="-6" r="3.9" fill="#FFFFFF"/><circle cx="{x - 3.5}" cy="3.5" r="1.8" fill="#FFFFFF"/><circle cx="{x + 4}" cy="3.5" r=".9" fill="#FFFFFF"/>'
        s += f'<g class="lids"><ellipse cx="-21" cy="-2" rx="10.5" ry="12" fill="{FUR}"/><ellipse cx="21" cy="-2" rx="10.5" ry="12" fill="{FUR}"/><path d="M-30,1 Q-21,6 -12,1 M12,1 Q21,6 30,1" fill="none" stroke="{EYE}" stroke-width="3" stroke-linecap="round"/></g>'
        return s
    if expr == "happy":
        return f'<path d="M-30,1 Q-21,-10 -12,1 M12,1 Q21,-10 30,1" fill="none" stroke="{EYE}" stroke-width="3.8" stroke-linecap="round"/>'
    return f'<path d="M-30,-1 Q-21,7 -12,-1 M12,-1 Q21,7 30,-1" fill="none" stroke="{EYE}" stroke-width="3.6" stroke-linecap="round"/>'


def head(cx, cy, s=1, expr="open", rot=0, glasses=False, cls="tilt"):
    droop = expr == "sad"
    g = [
        f'<g transform="translate({cx},{cy}) rotate({rot}) scale({s})"><g class="{cls}">',
        f'<g class="twitch-l">{ear(1, droop)}</g>',
        f'<g class="twitch-r">{ear(-1, droop)}</g>',
        f'<path d="{HEAD_D}" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/>',
        f'<path d="M-30,-30 Q0,-44 30,-30" fill="none" stroke="{FUR2}" stroke-width="7" stroke-linecap="round" opacity=".7"/>',
        f'<path d="M-4,-40 Q0,-50 5,-41" fill="none" stroke="{OUT}" stroke-width="2.6" stroke-linecap="round"/>',
        '<ellipse cx="-24" cy="-33" rx="9" ry="4" transform="rotate(-18 -24 -33)" fill="#FFFFFF" opacity=".22"/>',
        f'<g transform="translate(-36,12)"><path d="{CHEEK_L}" fill="{CREAM}"/></g><g transform="translate(36,12) scale(-1,1)"><path d="{CHEEK_L}" fill="{CREAM}"/></g>',
        f'<ellipse cx="0" cy="18" rx="27" ry="18" fill="{CREAM}"/>',
        f'<ellipse cx="-21" cy="-20" rx="10" ry="6.5" fill="{CREAM}"/><ellipse cx="21" cy="-20" rx="10" ry="6.5" fill="{CREAM}"/>',
        f'<path d="M-22,8 Q-26,19 -19,29 M22,8 Q26,19 19,29" fill="none" stroke="{SHADE}" stroke-width="6.5" stroke-linecap="round" opacity=".85"/>',
        eyes(expr),
    ]
    if glasses:
        g.append(
            f'<circle cx="-21" cy="-2" r="14" fill="#FFFFFF" fill-opacity=".18" stroke="{OUT}" stroke-width="2.6"/><circle cx="21" cy="-2" r="14" fill="#FFFFFF" fill-opacity=".18" stroke="{OUT}" stroke-width="2.6"/><path d="M-7,-4 Q0,-8 7,-4" fill="none" stroke="{OUT}" stroke-width="2.6"/>'
        )
    g.append(
        f'<path d="M-6.5,12 Q0,8 6.5,12 Q0,20 -6.5,12 Z" fill="{EYE}"/><ellipse cx="-1.8" cy="11.4" rx="1.8" ry="1" fill="#FFFFFF" opacity=".8"/>'
    )
    g.append(
        f'<g fill="{OUT}" opacity=".35"><circle cx="-14" cy="21" r="1.2"/><circle cx="-17" cy="25" r="1.2"/><circle cx="-12" cy="26" r="1.2"/><circle cx="14" cy="21" r="1.2"/><circle cx="17" cy="25" r="1.2"/><circle cx="12" cy="26" r="1.2"/></g>'
    )
    if expr in ("happy", "proud"):
        g.append(
            f'<path d="M-8.5,22 Q0,35 8.5,22 Z" fill="{MOUTH}" stroke="{OUT}" stroke-width="2" stroke-linejoin="round"/><ellipse cx="0" cy="28.5" rx="3.6" ry="2.2" fill="{PINK}"/>'
        )
    elif expr == "sad":  # a wobbly little frown
        g.append(
            f'<path d="M-8,27 Q-4,22 0,24.5 Q4,22 8,27" fill="none" stroke="{EYE}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
        )
    elif expr == "shock":  # jaw dropped
        g.append(
            f'<ellipse cx="0" cy="28" rx="6.5" ry="9" fill="{MOUTH}" stroke="{OUT}" stroke-width="2"/><ellipse cx="0" cy="32.5" rx="3.6" ry="2.6" fill="{PINK}"/>'
        )
    elif expr == "yawn":
        g.append(
            f'<g class="yawn"><ellipse cx="0" cy="28" rx="7.5" ry="10" fill="{MOUTH}" stroke="{OUT}" stroke-width="2"/><ellipse cx="0" cy="33" rx="4.5" ry="3.2" fill="{PINK}"/></g>'
        )
    else:
        g.append(
            f'<path d="M-7,22 Q-3.5,26 0,22 Q3.5,26 7,22" fill="none" stroke="{EYE}" stroke-width="2.2" stroke-linecap="round"/>'
        )
    g.append(
        f'<ellipse cx="-38" cy="22" rx="10" ry="6" fill="{PINK}" opacity=".32"/><ellipse cx="38" cy="22" rx="10" ry="6" fill="{PINK}" opacity=".32"/>'
        f'<ellipse cx="-38" cy="22" rx="6.5" ry="3.8" fill="{PINK}" opacity=".7"/><ellipse cx="38" cy="22" rx="6.5" ry="3.8" fill="{PINK}" opacity=".7"/>'
    )
    g.append("</g></g>")
    return "".join(g)


def tail(d, cls="tail"):
    return f'<g class="{cls}"><path d="{d}" fill="none" stroke="{OUT}" stroke-width="32" stroke-linecap="round"/><path d="{d}" fill="none" stroke="{FUR}" stroke-width="26" stroke-linecap="round"/><path d="{d}" fill="none" stroke="{RING}" stroke-width="26" stroke-dasharray="11 15" stroke-dashoffset="4"/><path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="4" stroke-dasharray="2 24" stroke-linecap="round" opacity=".35" transform="translate(-4,-4)"/></g>'


def body(cx, cy, rx=38, ry=33):
    shine = (
        f'<path d="M{cx - rx * 0.7:.0f},{cy - ry * 0.35:.0f} Q{cx - rx * 0.55:.0f},{cy - ry * 0.75:.0f} {cx - rx * 0.2:.0f},{cy - ry * 0.82:.0f}" '
        f'fill="none" stroke="{FUR2}" stroke-width="4.5" stroke-linecap="round" opacity=".65"/>'
    )
    return f'<path d="{fluffy(rx, ry, [(200, 340)], 6, 10)}" transform="translate({cx},{cy})" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><ellipse cx="{cx}" cy="{cy + 9}" rx="{rx * 0.58:.0f}" ry="{ry * 0.6:.0f}" fill="{DARK}"/><ellipse cx="{cx}" cy="{cy - ry + 10}" rx="{rx * 0.7:.0f}" ry="9" fill="{SHADE}" opacity=".35"/>{shine}'


def feet(cx, cy):
    return "".join(
        f'<ellipse cx="{cx + dx}" cy="{cy}" rx="14.5" ry="9.5" fill="{DARK}" stroke="{OUT}" stroke-width="3"/><path d="M{cx + dx - 6},{cy - 3} L{cx + dx - 6},{cy + 2} M{cx + dx},{cy - 4} L{cx + dx},{cy + 2} M{cx + dx + 6},{cy - 3} L{cx + dx + 6},{cy + 2}" stroke="{OUT}" stroke-width="1.6" stroke-linecap="round" opacity=".55"/>'
        for dx in (-19, 19)
    )


def arm(x, y, rot, ry=15, beans=False):
    s = f'<ellipse cx="{x}" cy="{y}" rx="10" ry="{ry}" transform="rotate({rot} {x} {y})" fill="{DARK}" stroke="{OUT}" stroke-width="3"/>'
    if beans:
        s += f'<g transform="rotate({rot} {x} {y})"><circle cx="{x}" cy="{y - ry + 7}" r="3.2" fill="{PINK}"/><circle cx="{x - 4.5}" cy="{y - ry + 2.5}" r="1.7" fill="{PINK}"/><circle cx="{x}" cy="{y - ry + 1}" r="1.7" fill="{PINK}"/><circle cx="{x + 4.5}" cy="{y - ry + 2.5}" r="1.7" fill="{PINK}"/></g>'
    return s


def shadow(cx, cy, rx=60, cls=""):
    soft = f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="8" fill="{OUT}" opacity=".07"/>'
    core = f'<ellipse cx="{cx}" cy="{cy}" rx="{rx * 0.7:.0f}" ry="5" fill="{OUT}" opacity=".09"/>'
    return f'<g class="{cls}">{soft}{core}</g>' if cls else soft + core


def star(x, y, r, col="#F2B640", cls="twinkle"):
    return f'<g class="{cls}"><path d="M{x},{y - r} Q{x + r * 0.22},{y - r * 0.22} {x + r},{y} Q{x + r * 0.22},{y + r * 0.22} {x},{y + r} Q{x - r * 0.22},{y + r * 0.22} {x - r},{y} Q{x - r * 0.22},{y - r * 0.22} {x},{y - r} Z" fill="{col}"/></g>'


def heart(x, y, cls):
    return f'<g class="{cls}"><path d="M{x},{y + 6} C{x - 10},{y - 1} {x - 6},{y - 10} {x},{y - 4} C{x + 6},{y - 10} {x + 10},{y - 1} {x},{y + 6} Z" fill="{PINK}" stroke="{OUT}" stroke-width="1.6"/></g>'


def pose_read():
    cx, cy = (120, 150)
    book = f'<g transform="translate({cx},{cy + 2})"><path d="M-33,-14 L0,-8 L0,20 L-33,14 Z" fill="#FFFFFF" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><g class="page"><path d="M33,-14 L0,-8 L0,20 L33,14 Z" fill="#EEF2FF" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/></g><path d="M-26,-5 L-7,-2 M-26,2 L-7,5 M-26,9 L-12,11" stroke="#9AA6D8" stroke-width="2" stroke-linecap="round"/></g>'
    return svg(
        shadow(cx, 203)
        + tail(f"M{cx + 30},{cy + 22} C{cx + 86},{cy + 26} {cx + 92},{cy - 36} {cx + 58},{cy - 54}")
        + '<g class="breathe">'
        + body(cx, cy)
        + "</g>"
        + feet(cx, cy + 34)
        + book
        + arm(cx - 30, cy + 4, 40, 12)
        + arm(cx + 30, cy + 4, -40, 12)
        + head(cx, cy - 60),
        label="Pip reading a book",
    )


def pose_happy():
    cx, cy = (120, 150)
    fig = (
        tail(f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}")
        + body(cx, cy)
        + feet(cx, cy + 34)
        + f'<g class="wave-l">{arm(cx - 42, cy - 22, 35, 16, True)}</g><g class="wave-r">{arm(cx + 42, cy - 22, -35, 16, True)}</g>'
        + head(cx, cy - 62, expr="happy", cls="")
    )
    return svg(
        shadow(cx, 206, 50, "shadow-hop")
        + f'<g class="hop">{fig}</g>'
        + star(38, 58, 9, cls="twinkle")
        + star(206, 40, 7, PINK, "twinkle t2")
        + star(200, 122, 6, cls="twinkle t3"),
        label="Pip doing a happy hop",
    )


def pose_nap():
    cx, cy = (128, 150)

    def zed(x, y, size, col):
        return f'<path d="M{x},{y} L{x + size},{y} L{x},{y + size} L{x + size},{y + size}" fill="none" stroke="{col}" stroke-width="{size * 0.24:.1f}" stroke-linecap="round" stroke-linejoin="round"/>'

    z = f'<g class="zz">{zed(186, 56, 14, "#8A7D76")}</g><g class="zz t2">{zed(204, 38, 10, "#B3A8A2")}</g>'
    bod = f'<g class="breathe-deep"><path d="{fluffy(66, 30, [(190, 350)], 6, 10)}" transform="translate({cx + 6},{cy + 18})" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/></g>'
    return svg(
        shadow(cx, 200, 78)
        + bod
        + tail(
            f"M{cx + 62},{cy + 18} C{cx + 70},{cy + 56} {cx - 40},{cy + 62} {cx - 74},{cy + 36}",
            "tail-soft",
        )
        + head(cx - 30, cy - 8, 0.9, "closed", -10, cls="nod")
        + z,
        label="Pip napping curled up",
    )


def pose_stretch():
    cx, cy = (132, 140)
    legs = f'<rect x="{cx - 100}" y="{cy + 22}" width="48" height="18" rx="9" fill="{DARK}" stroke="{OUT}" stroke-width="3" transform="rotate(-6 {cx - 77} {cy + 31})"/><rect x="{cx + 24}" y="{cy + 6}" width="20" height="46" rx="10" fill="{DARK}" stroke="{OUT}" stroke-width="3"/><rect x="{cx + 46}" y="{cy + 2}" width="20" height="50" rx="10" fill="{DARK}" stroke="{OUT}" stroke-width="3"/>'
    bod = f'<g transform="rotate(-14 {cx} {cy + 6})"><path d="{fluffy(64, 27, [(200, 330)], 6, 10)}" transform="translate({cx},{cy + 6})" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/></g>'
    return svg(
        shadow(cx - 10, 196, 90)
        + '<g class="stretch">'
        + tail(f"M{cx + 58},{cy - 10} C{cx + 86},{cy - 50} {cx + 64},{cy - 100} {cx + 36},{cy - 96}")
        + legs
        + bod
        + head(cx - 70, cy + 2, 0.86, "yawn", -8, cls="")
        + "</g>",
        label="Pip stretching and yawning",
    )


def pose_play():
    cx, cy = (138, 150)
    return svg(
        shadow(cx - 20, 204, 80)
        + tail(f"M{cx + 30},{cy + 18} C{cx + 80},{cy + 10} {cx + 86},{cy - 48} {cx + 56},{cy - 64}")
        + body(cx, cy)
        + feet(cx, cy + 34)
        + f'<g class="roll">{yarn(48, 176, 22)}</g>'
        + f'<g class="swipe">{arm(cx - 44, cy + 12, 62, 17)}</g>'
        + arm(cx + 28, cy + 8, -30, 12)
        + head(cx - 4, cy - 60, expr="open", rot=-8, cls="watch"),
        label="Pip batting a ball of yarn",
    )


def pose_hug():
    cx, cy = (120, 150)
    fig = (
        tail(f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}")
        + body(cx, cy)
        + feet(cx, cy + 34)
        + yarn(cx, cy + 6, 24, True)
        + arm(cx - 26, cy + 4, 50, 13)
        + arm(cx + 26, cy + 4, -50, 13)
        + head(cx, cy - 62, expr="happy", cls="")
    )
    return svg(
        shadow(cx, 206, 50)
        + f'<g class="rock">{fig}</g>'
        + heart(52, 86, "heart")
        + heart(190, 70, "heart t2")
        + heart(64, 40, "heart t3"),
        label="Pip hugging a wound-up ball of yarn",
    )


def pose_focus():
    cx, cy = (120, 146)
    lap = f'<path d="M{cx - 44},{cy + 22} L{cx + 44},{cy + 22} L{cx + 54},{cy + 36} L{cx - 54},{cy + 36} Z" fill="#C9CFE0" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><rect x="{cx - 40}" y="{cy - 22}" width="80" height="46" rx="6" fill="#DDE3F2" stroke="{OUT}" stroke-width="3"/><g class="spin"><circle cx="{cx}" cy="{cy}" r="9" fill="none" stroke="#6F8FE8" stroke-width="3.5" stroke-dasharray="44 14" stroke-linecap="round"/></g>'
    return svg(
        shadow(cx, 206, 70)
        + tail(f"M{cx + 30},{cy + 18} C{cx + 84},{cy + 20} {cx + 92},{cy - 40} {cx + 60},{cy - 58}")
        + '<g class="breathe">'
        + body(cx, cy)
        + "</g>"
        + head(cx, cy - 60, expr="open", glasses=True, cls="bob")
        + lap
        + f'<g class="type-l">{arm(cx - 40, cy + 24, 70, 11)}</g><g class="type-r">{arm(cx + 40, cy + 24, -70, 11)}</g>',
        label="Pip studying with glasses at a laptop",
    )


def pose_proud():
    cx, cy = (120, 150)
    medal = f'<g class="swing"><path d="M{cx - 6},{cy - 24} L{cx},{cy - 6} L{cx + 6},{cy - 24}" fill="none" stroke="#6F8FE8" stroke-width="4"/><circle cx="{cx}" cy="{cy + 4}" r="11" fill="#F2B640" stroke="{OUT}" stroke-width="3"/>{star(cx, cy + 4, 6, "#FFF4E6", "")}</g>'
    fig = (
        tail(f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}")
        + '<g class="puff">'
        + body(cx, cy)
        + "</g>"
        + feet(cx, cy + 34)
        + arm(cx - 38, cy + 2, 20, 14)
        + arm(cx + 38, cy + 2, -20, 14)
        + medal
        + head(cx, cy - 62, expr="proud")
    )
    return svg(
        shadow(cx, 206, 50)
        + fig
        + star(40, 66, 10)
        + star(204, 54, 9, cls="twinkle t2")
        + star(30, 130, 6, PINK, "twinkle t3"),
        label="Pip proud with a medal",
    )


def pose_sad():
    """Only for the silly "Pip misses you" nudges (Settings → Nudges can turn them off): a droopy, teary Pip under
    its own little rain cloud. Played for laughs, never for guilt."""
    cx, cy = (120, 152)

    def drop(x, y, cls):
        return f'<g class="{cls}"><path d="M{x},{y} Q{x - 3},{y + 6} {x},{y + 8} Q{x + 3},{y + 6} {x},{y} Z" fill="#8CC4F5"/></g>'

    cloud = (
        '<g class="drift">'
        f'<path d="M150,44 Q148,28 164,28 Q170,16 184,22 Q198,18 200,32 Q212,34 208,46 Q206,54 194,52 L160,52 Q150,52 150,44 Z" fill="#C8CFDB" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
        f'<path d="M160,40 Q166,34 172,38" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round" opacity=".6"/>'
        + drop(162, 58, "drip")
        + drop(178, 62, "drip t2")
        + drop(194, 58, "drip t3")
        + "</g>"
    )
    return svg(
        shadow(cx, 205)
        + tail(
            f"M{cx + 30},{cy + 30} C{cx + 70},{cy + 44} {cx + 98},{cy + 40} {cx + 100},{cy + 22}", "tail-soft"
        )
        + '<g class="sigh">'
        + body(cx, cy)
        + "</g>"
        + feet(cx, cy + 34)
        + arm(cx - 22, cy + 8, 12, 14)
        + arm(cx + 22, cy + 8, -12, 14)
        + head(cx, cy - 54, expr="sad", rot=4, cls="sigh")
        + cloud,
        label="Pip sad under a little rain cloud",
    )


def pose_shocked():
    """Only for the silly nudge after a day away by default (with the "fahhh"): fur on end, paws on cheeks."""
    cx, cy = (120, 152)

    def bang(x, y, rot, cls):
        return f'<g class="{cls}"><g transform="rotate({rot} {x} {y})"><rect x="{x - 3}" y="{y - 14}" width="6" height="15" rx="3" fill="#E2577E"/><circle cx="{x}" cy="{y + 6}" r="3.2" fill="#E2577E"/></g></g>'

    poofed = f'<path d="{fluffy(41, 35, [(0, 360)], 7, 7)}" transform="translate({cx},{cy})" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><ellipse cx="{cx}" cy="{cy + 9}" rx="23" ry="20" fill="{DARK}"/>'
    return svg(
        shadow(cx, 205)
        + '<g class="shiver">'
        + tail(f"M{cx + 30},{cy + 18} C{cx + 70},{cy + 6} {cx + 74},{cy - 50} {cx + 60},{cy - 84}", "")
        + poofed
        + feet(cx, cy + 34)
        + head(cx, cy - 62, expr="shock", cls="")
        + arm(cx - 44, cy - 54, 18, 15, True)
        + arm(cx + 44, cy - 54, -18, 15, True)
        + "</g>"
        + bang(40, 54, -18, "alarm")
        + bang(200, 50, 18, "alarm t2")
        + bang(208, 96, 30, "alarm t3"),
        label="Pip shocked, paws on cheeks",
    )


# Every animation, as data: the CSS (explainer videos) and pip-rig.json (the Mac app) are both made from this.
# Each key is (percent, {tx, ty (px), r (deg), sx, sy, o (opacity)}); missing values are identity.
# origin: the pivot as a percentage of the animated group's own box (CSS transform-origin with transform-box: fill-box).
EASE = {
    "ease": (0.25, 0.1, 0.25, 1),
    "ease-in-out": (0.42, 0, 0.58, 1),
    "ease-in": (0.42, 0, 1, 1),
    "linear": (0, 0, 1, 1),
}
ANIM = {
    # A soft sway with a little follow-through at the top.
    "tail": dict(
        origin=(0, 100),
        dur=3.4,
        ease="ease-in-out",
        keys=[(0, {}), (42, {"r": 9}), (58, {"r": 7}), (100, {})],
    ),
    "tail-soft": dict(
        origin=(100, 20), dur=4.4, ease="ease-in-out", keys=[(0, {}), (50, {"r": -3}), (100, {})]
    ),
    # Eyes open most of the time; one blink, then a double blink, over eight seconds.
    "lids": dict(
        origin=(50, 50),
        dur=8,
        ease="ease",
        rest={"sy": 0},
        keys=[
            (0, {"sy": 0}),
            (41, {"sy": 0}),
            (43, {"sy": 1}),
            (45.5, {"sy": 0}),
            (86, {"sy": 0}),
            (88, {"sy": 1}),
            (90, {"sy": 0}),
            (91.5, {"sy": 1}),
            (93.5, {"sy": 0}),
            (100, {"sy": 0}),
        ],
    ),
    # Ears twitch now and then (different periods, so they never move together).
    "twitch-l": dict(
        origin=(85, 100),
        dur=6.7,
        ease="ease-in-out",
        keys=[(0, {}), (86, {}), (89, {"r": -13}), (92, {}), (94, {"r": -6}), (97, {}), (100, {})],
    ),
    "twitch-r": dict(
        origin=(15, 100),
        dur=9.1,
        ease="ease-in-out",
        keys=[(0, {}), (78, {}), (81, {"r": 13}), (84, {}), (100, {})],
    ),
    "tilt": dict(
        origin=(50, 90),
        dur=5.5,
        ease="ease-in-out",
        keys=[(0, {}), (30, {"r": -4}), (65, {"r": 3}), (100, {})],
    ),
    "nod": dict(
        origin=(50, 90), dur=4.4, ease="ease-in-out", keys=[(0, {}), (50, {"ty": 2, "r": -2}), (100, {})]
    ),
    "watch": dict(origin=(50, 90), dur=1.4, ease="ease-in-out", keys=[(0, {}), (35, {"r": -6}), (100, {})]),
    "bob": dict(origin=(50, 90), dur=1.8, ease="ease-in-out", keys=[(0, {}), (50, {"ty": 2.5}), (100, {})]),
    "breathe": dict(
        origin=(50, 100),
        dur=3.6,
        ease="ease-in-out",
        keys=[(0, {}), (50, {"sx": 1.025, "sy": 1.04}), (100, {})],
    ),
    "breathe-deep": dict(
        origin=(50, 100),
        dur=4.4,
        ease="ease-in-out",
        keys=[(0, {}), (50, {"sx": 1.03, "sy": 1.07}), (100, {})],
    ),
    "puff": dict(
        origin=(50, 100),
        dur=2.2,
        ease="ease-in-out",
        keys=[(0, {}), (50, {"sx": 1.05, "sy": 1.05}), (100, {})],
    ),
    # Squash, leap, stretch, land.
    "hop": dict(
        origin=(50, 100),
        dur=1.1,
        ease=(0.3, 0, 0.4, 1),
        keys=[
            (0, {"sx": 1.06, "sy": 0.94}),
            (15, {}),
            (50, {"ty": -18, "sx": 0.97, "sy": 1.04}),
            (85, {}),
            (100, {"sx": 1.06, "sy": 0.94}),
        ],
    ),
    "shadow-hop": dict(
        origin=(50, 50),
        dur=1.1,
        ease=(0.3, 0, 0.4, 1),
        rest={"o": 1},
        keys=[(0, {}), (50, {"sx": 0.7, "sy": 0.7, "o": 0.55}), (100, {})],
    ),
    "rock": dict(
        origin=(50, 100),
        dur=2.6,
        ease="ease-in-out",
        rest={"r": 0},
        keys=[(0, {"r": -3}), (50, {"r": 3}), (100, {"r": -3})],
    ),
    "wave-l": dict(
        origin=(80, 100),
        dur=0.55,
        ease="ease-in-out",
        alternate=True,
        keys=[(0, {"r": -8}), (100, {"r": 10})],
    ),
    "wave-r": dict(
        origin=(20, 100),
        dur=0.55,
        ease="ease-in-out",
        alternate=True,
        keys=[(0, {"r": 8}), (100, {"r": -10})],
    ),
    "twinkle": dict(
        origin=(50, 50),
        dur=1.8,
        ease="ease-in-out",
        keys=[
            (0, {"sx": 0.6, "sy": 0.6, "o": 0.4}),
            (50, {"sx": 1.15, "sy": 1.15, "o": 1}),
            (100, {"sx": 0.6, "sy": 0.6, "o": 0.4}),
        ],
    ),
    "zz": dict(
        origin=(50, 50),
        dur=2.8,
        ease="ease-in-out",
        keys=[(0, {"o": 0}), (25, {"tx": 1.5, "ty": -4, "o": 1}), (100, {"tx": 6, "ty": -16, "o": 0})],
    ),
    "stretch": dict(
        origin=(100, 100), dur=3.4, ease="ease-in-out", keys=[(0, {}), (50, {"sx": 1.05, "ty": 2}), (100, {})]
    ),
    "yawn": dict(
        origin=(50, 0),
        dur=3.4,
        ease="ease-in-out",
        rest={"sy": 0.35},
        keys=[
            (0, {"sy": 0.35}),
            (20, {"sy": 0.35}),
            (50, {"sy": 1.1}),
            (70, {"sy": 1.1}),
            (100, {"sy": 0.35}),
        ],
    ),
    "swipe": dict(
        origin=(100, 0),
        dur=1.5,
        ease="ease-in-out",
        keys=[(0, {}), (30, {"r": -22}), (45, {"r": 4}), (100, {})],
    ),
    "roll": dict(
        origin=(50, 50),
        dur=1.5,
        ease="ease-in-out",
        keys=[(0, {}), (28, {}), (55, {"tx": -7, "r": -40}), (100, {})],
    ),
    "heart": dict(
        origin=(50, 50),
        dur=2.6,
        ease="ease-in",
        keys=[
            (0, {"ty": 8, "sx": 0.6, "sy": 0.6, "o": 0}),
            (30, {"ty": -1, "sx": 0.85, "sy": 0.85, "o": 1}),
            (100, {"ty": -22, "o": 0}),
        ],
    ),
    "spin": dict(origin=(50, 50), dur=1.1, ease="linear", keys=[(0, {}), (100, {"r": 360})]),
    "type-l": dict(
        origin=(50, 0), dur=0.36, ease="ease-in-out", alternate=True, keys=[(0, {}), (100, {"ty": -3})]
    ),
    "type-r": dict(
        origin=(50, 0),
        dur=0.36,
        ease="ease-in-out",
        alternate=True,
        reverse=True,
        keys=[(0, {}), (100, {"ty": -3})],
    ),
    "swing": dict(
        origin=(50, 0), dur=1.8, ease="ease-in-out", keys=[(0, {"r": -9}), (50, {"r": 9}), (100, {"r": -9})]
    ),
    "page": dict(
        origin=(0, 50),
        dur=4.8,
        ease="ease-in-out",
        keys=[(0, {}), (70, {}), (80, {"sx": 0.2}), (90, {}), (100, {})],
    ),
}
ANIM.update(
    {
        # The silly nudges: a slow sigh, one tear at a time, rain from Pip's cloud, a shiver, and "!" popping.
        "sigh": dict(
            origin=(50, 100), dur=4.2, ease="ease-in-out", keys=[(0, {}), (50, {"ty": 3, "r": -2}), (100, {})]
        ),
        "tear": dict(
            origin=(50, 0),
            dur=2.6,
            ease="ease-in",
            keys=[
                (0, {"sy": 0.4, "o": 0}),
                (25, {"o": 1}),
                (70, {"ty": 10, "o": 1}),
                (100, {"ty": 16, "o": 0}),
            ],
        ),
        "drip": dict(
            origin=(50, 50),
            dur=1.3,
            ease="ease-in",
            keys=[(0, {"o": 0}), (20, {"o": 1}), (100, {"ty": 26, "o": 0})],
        ),
        "drift": dict(
            origin=(50, 50), dur=5, ease="ease-in-out", keys=[(0, {}), (50, {"tx": -4, "ty": 1}), (100, {})]
        ),
        "shiver": dict(
            origin=(50, 100),
            dur=0.5,
            ease="linear",
            keys=[(0, {}), (25, {"tx": -1.6, "r": -1}), (75, {"tx": 1.6, "r": 1}), (100, {})],
        ),
        "alarm": dict(
            origin=(50, 100),
            dur=1.2,
            ease="ease-in-out",
            keys=[
                (0, {"sx": 0.7, "sy": 0.7, "o": 0.3}),
                (40, {"sx": 1.2, "sy": 1.2, "o": 1}),
                (100, {"o": 0.3}),
            ],
        ),
    }
)
DELAYS = {"t2": -0.6, "t3": -1.2}


def _transform(v: dict) -> str:
    return (
        f"translate({v.get('tx', 0)}px,{v.get('ty', 0)}px) rotate({v.get('r', 0)}deg) "
        f"scale({v.get('sx', 1)},{v.get('sy', 1)})"
    )


def _ease(e) -> str:
    return e if isinstance(e, str) else "cubic-bezier({},{},{},{})".format(*e)


def build_css() -> str:
    boxes = ",".join(f".pip .{name}" for name in ANIM)
    out = [boxes + "{transform-box:fill-box}"]
    for name, a in ANIM.items():
        rest = f";transform:{_transform(a['rest'])}" if "rest" in a and set(a["rest"]) - {"o"} else ""
        opacity = f";opacity:{a['rest']['o']}" if "o" in a.get("rest", {}) and name != "shadow-hop" else ""
        out.append(f".pip .{name}{{transform-origin:{a['origin'][0]}% {a['origin'][1]}%{rest}{opacity}}}")
    out.append("@media (prefers-reduced-motion:no-preference){")
    for name, a in ANIM.items():
        direction = " alternate-reverse" if a.get("reverse") else " alternate" if a.get("alternate") else ""
        out.append(
            f".moving .{name}{{animation:nl-{name} {a['dur']}s {_ease(a['ease'])} infinite{direction}}}"
        )
    out.append("".join(f".moving .{k}{{animation-delay:{v}s}}" for k, v in DELAYS.items()))
    out.append("}")
    for name, a in ANIM.items():
        frames = "".join(
            f"{t}%{{transform:{_transform(v)}" + (f";opacity:{v['o']}" if "o" in v else "") + "}"
            for t, v in a["keys"]
        )
        out.append(f"@keyframes nl-{name}{{{frames}}}")
    return "\n".join(out)


CSS = build_css()

POSES = {
    "read": pose_read,
    "hop": pose_happy,
    "nap": pose_nap,
    "stretch": pose_stretch,
    "play": pose_play,
    "hug": pose_hug,
    "study": pose_focus,
    "proud": pose_proud,
    "sad": pose_sad,  # the silly nudges only
    "shocked": pose_shocked,
}
OUTPUTS = ("pipeline/neuralloop_books/assets/pip-poses.js",)  # explainer videos (CSS animation)
RIG = "apple/App/Resources/pip-rig.json"  # the Mac and iPad apps (layers, pivots, keyframes)
LAYERS = "apple/App/Resources/PipLayers"  # each layer as a PNG (UIImage can't draw SVG, and bitmaps are cheap to move)
SCALE = 3  # layers are drawn at 3x the viewBox (720x660 for 240x220): sharp on Retina with room for hops and puffs
ICON_SIZE = (19, 18)  # the menu-bar icon, in points


def build_js() -> str:
    poses = {
        name: draw().replace('width="100%" height="100%"', 'width="100%"') for name, draw in POSES.items()
    }
    poses["icon"] = (
        f'<svg viewBox="-64 -68 128 122" width="100%" aria-hidden="true">{head(0, 0, 1, "happy", cls="tilt")}</svg>'
    )
    return f"window.PIP={json.dumps(poses)};\nwindow.PIP_CSS={json.dumps(CSS)};\n"


def _layers(svg_text: str) -> tuple[list, list, str]:
    """Split a pose into ordered layers: runs of drawing that share the same chain of animated groups.
    Returns (layers, animated groups in document order, the pose with measuring ids)."""
    import xml.etree.ElementTree as ET

    root = ET.fromstring(svg_text)
    groups: list[dict] = []
    leaves: list[tuple[tuple, list, ET.Element]] = []

    def visit(node, chain, wrappers):
        for child in node:
            if child.tag == "g":
                classes = (child.get("class") or "").split()
                name = next((c for c in classes if c in ANIM), None)
                attrs = {k: v for k, v in child.attrib.items() if k != "class"}
                if name:
                    delay = sum(DELAYS.get(c, 0) for c in classes)
                    groups.append({"id": len(groups), "anim": name, "delay": delay})
                    child.set("data-rig", str(len(groups) - 1))
                    visit(child, (*chain, len(groups) - 1), [*wrappers, attrs])
                else:
                    visit(child, chain, [*wrappers, attrs])
            else:
                leaves.append((chain, wrappers, child))

    visit(root, (), [])
    layers: list[dict] = []
    for chain, wrappers, leaf in leaves:
        if not layers or tuple(layers[-1]["chain"]) != chain:
            layers.append({"chain": list(chain), "parts": []})
        opened = "".join("<g " + " ".join(f'{k}="{v}"' for k, v in w.items()) + ">" for w in wrappers)
        layers[-1]["parts"].append(opened + ET.tostring(leaf, encoding="unicode") + "</g>" * len(wrappers))
    view_box = root.get("viewBox")
    for layer in layers:
        layer["svg"] = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}" width="480" height="440">'
            + "".join(layer.pop("parts"))
            + "</svg>"
        )
    return layers, groups, ET.tostring(root, encoding="unicode")


def _art_hash(svg_text: str) -> str:
    return hashlib.sha1(svg_text.encode("utf-8")).hexdigest()[:12]


def _render_png(page, svg_text: str, width: int, height: int, target: Path) -> None:
    """One transparent PNG of `svg_text` at width x height pixels."""
    page.set_viewport_size({"width": width, "height": height})
    page.set_content(
        "<html><head><style>html,body{margin:0;background:transparent}svg{display:block}</style></head>"
        f"<body>{svg_text}</body></html>"
    )
    page.screenshot(
        path=str(target), omit_background=True, clip={"x": 0, "y": 0, "width": width, "height": height}
    )


def _plan() -> tuple[dict, dict]:
    """Everything about the rig that needs no browser: per pose its label, viewBox, pixel size, the SVG to measure,
    its animated groups, and its layers (image name, chain, SVG, art hash); and the same for the menu-bar icon."""
    poses = {}
    for name, draw in POSES.items():
        svg_text = draw().replace('width="100%" height="100%"', 'width="480" height="440"')
        layers, groups, measured = _layers(svg_text)
        label = svg_text.split('aria-label="', 1)[1].split('"', 1)[0]
        view_box = [float(v) for v in svg_text.split('viewBox="', 1)[1].split('"', 1)[0].split()]
        width, height = round(view_box[2] * SCALE), round(view_box[3] * SCALE)
        planned = []
        for index, layer in enumerate(layers):
            layer_svg = layer["svg"].replace('width="480" height="440"', f'width="{width}" height="{height}"')
            art = _art_hash(f"{width}x{height}:{layer_svg}")
            planned.append(
                {"chain": layer["chain"], "image": f"{name}-{index}", "svg": layer_svg, "art": art}
            )
        poses[name] = {
            "label": label,
            "viewBox": view_box,
            "size": (width, height),
            "measured": measured,
            "groups": groups,
            "layers": planned,
        }
    icon_w, icon_h = ICON_SIZE
    icon_svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-64 -68 128 122" width="{icon_w * SCALE}" '
        f'height="{icon_h * SCALE}">{head(0, 0, 1, "happy", cls="")}</svg>'
    )
    size = (icon_w * SCALE, icon_h * SCALE)
    icon = {
        "image": "icon",
        "svg": icon_svg,
        "size": size,
        "art": _art_hash(f"{size[0]}x{size[1]}:{icon_svg}"),
    }
    return poses, icon


def _anims() -> dict:
    return {
        name: {
            "dur": a["dur"],
            "ease": list(EASE[a["ease"]] if isinstance(a["ease"], str) else a["ease"]),
            "alternate": bool(a.get("alternate")),
            "reverse": bool(a.get("reverse")),
            "rest": a.get("rest", {}),
            "keys": [{"t": t, **v} for t, v in a["keys"]],
        }
        for name, a in ANIM.items()
    }


def _vector_icon() -> str:
    # The icon also stays vector (the Mac menu bar draws it crisply at any size); `iconImage` is the PNG for the iPad.
    icon_w, icon_h = ICON_SIZE
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-64 -68 128 122" width="{icon_w * 2}" '
        f'height="{icon_h * 2}">{head(0, 0, 1, "happy", cls="")}</svg>'
    )


def build_rig(root: Path | None = None, force: bool = False) -> dict:
    """pip-rig.json: every pose as layers, each animated group's pivot and frame (measured in Chromium, like CSS
    transform-box: fill-box), and the keyframes. The app nests transforms like SVG does (eyelids ride on the head).
    Each layer is also drawn to PipLayers/<pose>-<index>.png. A layer's `art` is a hash of its SVG: a PNG is only
    redrawn when its art changes (or with `force`), so the same artwork gives the same files on every machine."""
    from playwright.sync_api import sync_playwright

    root = root or Path(__file__).resolve().parents[2]
    previous: dict = {}
    try:
        old = json.loads((root / RIG).read_text(encoding="utf-8"))
        previous = {
            layer.get("image"): layer.get("art") for pose in old["poses"].values() for layer in pose["layers"]
        }
        previous["icon"] = old.get("iconArt")
    except (OSError, ValueError, KeyError):  # no rig yet, or an older shape: draw everything
        pass
    out_dir = root / LAYERS
    out_dir.mkdir(parents=True, exist_ok=True)
    wanted: set[str] = set()

    def draw_png(page, name: str, svg_text: str, size: tuple[int, int], art: str) -> None:
        target = out_dir / f"{name}.png"
        wanted.add(target.name)
        if force or previous.get(name) != art or not target.exists():
            _render_png(page, svg_text, size[0], size[1], target)

    planned, icon = _plan()
    poses = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        for name, plan in planned.items():
            page.set_viewport_size({"width": 480, "height": 440})
            page.set_content(f"<html><body style='margin:0'>{plan['measured']}</body></html>")
            boxes = page.evaluate("""() => {
                const svg = document.querySelector('svg');
                const toRoot = svg.getCTM().inverse();
                return [...document.querySelectorAll('[data-rig]')].map(el => {
                    const b = el.getBBox(); const m = toRoot.multiply(el.getCTM());
                    return {id: +el.dataset.rig, box: [b.x, b.y, b.width, b.height], m: [m.a, m.b, m.c, m.d, m.e, m.f]};
                });
            }""")
            by_id = {b["id"]: b for b in boxes}
            chain_info = []
            for g in plan["groups"]:
                b = by_id[g["id"]]
                ox, oy = ANIM[g["anim"]]["origin"]
                x, y, w, h = b["box"]
                lx, ly = x + w * ox / 100, y + h * oy / 100
                a_, b_, c_, d_, e_, f_ = b["m"]
                pivot = [round(a_ * lx + c_ * ly + e_, 2), round(b_ * lx + d_ * ly + f_, 2)]
                chain_info.append(
                    {
                        "anim": g["anim"],
                        "delay": g["delay"],
                        "pivot": pivot,
                        "frame": [round(v, 4) for v in (a_, b_, c_, d_)],
                    }
                )
            rig_layers = []
            for layer in plan["layers"]:
                draw_png(page, layer["image"], layer["svg"], plan["size"], layer["art"])
                rig_layers.append({"chain": layer["chain"], "image": layer["image"], "art": layer["art"]})
            poses[name] = {
                "label": plan["label"],
                "viewBox": plan["viewBox"],
                "groups": chain_info,
                "layers": rig_layers,
            }
        draw_png(page, icon["image"], icon["svg"], icon["size"], icon["art"])
        browser.close()
    for stale in out_dir.glob("*.png"):
        if stale.name not in wanted:
            stale.unlink()
    return {
        "poses": poses,
        "anims": _anims(),
        "icon": _vector_icon(),
        "iconImage": icon["image"],
        "iconSize": list(ICON_SIZE),
        "iconArt": icon["art"],
        "scale": SCALE,
    }


def _png_size(path: Path) -> tuple[int, int] | None:
    """Width and height from a PNG's header, or None when the file isn't a PNG."""
    with path.open("rb") as f:
        head_bytes = f.read(24)
    if len(head_bytes) < 24 or head_bytes[:8] != b"\x89PNG\r\n\x1a\n" or head_bytes[12:16] != b"IHDR":
        return None
    return int.from_bytes(head_bytes[16:20], "big"), int.from_bytes(head_bytes[20:24], "big")


def check(root: Path | None = None) -> list[str]:
    """Problems with the committed artwork, found without a browser (so the same on every OS): the explainer
    script must match, pip-rig.json's layers, art hashes, groups, keyframes, and icon must match the current
    artwork, and every layer PNG it names must exist at the right size, with no stray PNGs. PNG bytes are not
    compared (Chromium's encoder differs across systems); pivots need a browser, so the regenerate-and-diff step
    covers them."""
    root = root or Path(__file__).resolve().parents[2]
    problems = []
    js = build_js()
    for relative in OUTPUTS:
        path = root / relative
        if not path.exists() or path.read_text(encoding="utf-8") != js:
            problems.append(f"{relative} is out of date")
    try:
        rig = json.loads((root / RIG).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [*problems, f"{RIG} can't be read ({error})"]
    planned, icon = _plan()
    out_dir = root / LAYERS
    wanted = {f"{icon['image']}.png": icon["size"]}
    if set(rig.get("poses", {})) != set(planned):
        problems.append(f"{RIG} has poses {sorted(rig.get('poses', {}))}, the artwork has {sorted(planned)}")
    for name, plan in planned.items():
        pose = rig.get("poses", {}).get(name, {})
        want_layers = [{"chain": x["chain"], "image": x["image"], "art": x["art"]} for x in plan["layers"]]
        if pose.get("layers") != want_layers:
            problems.append(f"{RIG}: pose '{name}' has different layers or art than the artwork")
        got_groups = [(g.get("anim"), g.get("delay")) for g in pose.get("groups", [])]
        if got_groups != [(g["anim"], g["delay"]) for g in plan["groups"]]:
            problems.append(f"{RIG}: pose '{name}' has different animated groups than the artwork")
        if pose.get("label") != plan["label"] or pose.get("viewBox") != plan["viewBox"]:
            problems.append(f"{RIG}: pose '{name}' has a different label or viewBox")
        wanted.update({f"{x['image']}.png": plan["size"] for x in plan["layers"]})
    expected = {
        "anims": _anims(),
        "icon": _vector_icon(),
        "iconImage": icon["image"],
        "iconSize": list(ICON_SIZE),
        "iconArt": icon["art"],
        "scale": SCALE,
    }
    problems += [f"{RIG}: '{key}' is out of date" for key, value in expected.items() if rig.get(key) != value]
    for file, size in sorted(wanted.items()):
        path = out_dir / file
        if not path.is_file():
            problems.append(f"{LAYERS}/{file} is missing")
        elif _png_size(path) != tuple(size):
            problems.append(f"{LAYERS}/{file} is {_png_size(path)}, expected {tuple(size)}")
    problems += [
        f"{LAYERS}/{p.name} isn't in {RIG}" for p in sorted(out_dir.glob("*.png")) if p.name not in wanted
    ]
    return problems


def main() -> None:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Regenerate Pip's artwork (see the top of this file).")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--force", action="store_true", help="redraw every layer PNG, even when its art is unchanged"
    )
    mode.add_argument(
        "--check", action="store_true", help="write nothing; fail if the committed artwork is out of date"
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.check:
        problems = check(root)
        for problem in problems:
            print(f"✗ {problem}", file=sys.stderr)
        if problems:
            sys.exit(
                "Pip's artwork is out of date: run `python design/pip/generate_pip.py` and commit the result."
            )
        print("Pip's artwork is up to date.")
        return
    js = build_js()
    for relative in OUTPUTS:
        (root / relative).write_text(js, encoding="utf-8")
        print(f"wrote {relative}")
    (root / RIG).write_text(
        json.dumps(build_rig(root, force=args.force), separators=(",", ":")), encoding="utf-8"
    )
    print(f"wrote {RIG} and {LAYERS}/")


if __name__ == "__main__":
    main()
