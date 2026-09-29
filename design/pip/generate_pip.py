"""Pip the red panda: the single source of truth for Pip's artwork and animation.

Run `python design/pip/generate_pip.py` from the repo root to regenerate:
  - pipeline/site/pip-poses.js   (study site)
  - src/pip-poses.js             (desktop app)
Never edit those files by hand. See docs/specs/03-pip-design-system.md.
"""

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
    mid = lambda p, q: ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)
    m0 = mid(pts[-1], pts[0])
    d = f"M{m0[0]:.1f},{m0[1]:.1f}"
    for i, p in enumerate(pts):
        m = mid(p, pts[(i + 1) % n])
        d += f" Q{p[0]:.1f},{p[1]:.1f} {m[0]:.1f},{m[1]:.1f}"
    return d + " Z"


HEAD_D = fluffy(51, 43, [(18, 70), (110, 162)], 9)
CHEEK_L = fluffy(16, 14, [(100, 250)], 5, step=15)


def ear(side):
    return f'<g transform="scale({side},1)"><path d="M-48,-6 C-63,-42 -48,-62 -21,-46 C-30,-30 -36,-16 -48,-6 Z" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><path d="M-43,-13 C-53,-37 -44,-50 -28,-42 C-33,-31 -37,-22 -43,-13 Z" fill="{CREAM}"/><path d="M-40,-18 L-44,-30 M-36,-20 L-37,-34" stroke="{RING}" stroke-width="2" stroke-linecap="round"/></g>'


def eyes(expr):
    if expr in ("open", "proud"):
        s = ""
        for x in (-21, 21):
            s += f'<ellipse cx="{x}" cy="-2" rx="9" ry="10.5" fill="{EYE}"/><ellipse cx="{x}" cy="2.5" rx="6.2" ry="5" fill="{IRIS}" opacity=".9"/><circle cx="{x + 3}" cy="-6" r="3.4" fill="#FFFFFF"/><circle cx="{x - 3}" cy="3" r="1.6" fill="#FFFFFF"/><circle cx="{x + 4}" cy="3.5" r=".9" fill="#FFFFFF"/>'
        s += f'<g class="lids"><ellipse cx="-21" cy="-2" rx="10.5" ry="12" fill="{FUR}"/><ellipse cx="21" cy="-2" rx="10.5" ry="12" fill="{FUR}"/><path d="M-30,1 Q-21,6 -12,1 M12,1 Q21,6 30,1" fill="none" stroke="{EYE}" stroke-width="3" stroke-linecap="round"/></g>'
        return s
    if expr == "happy":
        return f'<path d="M-30,1 Q-21,-10 -12,1 M12,1 Q21,-10 30,1" fill="none" stroke="{EYE}" stroke-width="3.8" stroke-linecap="round"/>'
    return f'<path d="M-30,-1 Q-21,7 -12,-1 M12,-1 Q21,7 30,-1" fill="none" stroke="{EYE}" stroke-width="3.6" stroke-linecap="round"/>'


def head(cx, cy, s=1, expr="open", rot=0, glasses=False, cls="tilt"):
    g = [
        f'<g transform="translate({cx},{cy}) rotate({rot}) scale({s})"><g class="{cls}">',
        ear(1),
        ear(-1),
        f'<path d="{HEAD_D}" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/>',
        f'<path d="M-30,-30 Q0,-44 30,-30" fill="none" stroke="{FUR2}" stroke-width="7" stroke-linecap="round" opacity=".7"/>',
        f'<path d="M-4,-40 Q0,-50 5,-41" fill="none" stroke="{OUT}" stroke-width="2.6" stroke-linecap="round"/>',
        f'<g transform="translate(-36,12)"><path d="{CHEEK_L}" fill="{CREAM}"/></g><g transform="translate(36,12) scale(-1,1)"><path d="{CHEEK_L}" fill="{CREAM}"/></g>',
        f'<ellipse cx="0" cy="18" rx="27" ry="18" fill="{CREAM}"/>',
        f'<ellipse cx="-21" cy="-20" rx="10" ry="6.5" fill="{CREAM}"/><ellipse cx="21" cy="-20" rx="10" ry="6.5" fill="{CREAM}"/>',
        f'<path d="M-22,8 Q-26,19 -19,29 M22,8 Q26,19 19,29" fill="none" stroke="{FUR}" stroke-width="6" stroke-linecap="round"/>',
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
    elif expr == "yawn":
        g.append(
            f'<g class="yawn"><ellipse cx="0" cy="28" rx="7.5" ry="10" fill="{MOUTH}" stroke="{OUT}" stroke-width="2"/><ellipse cx="0" cy="33" rx="4.5" ry="3.2" fill="{PINK}"/></g>'
        )
    else:
        g.append(
            f'<path d="M-7,22 Q-3.5,26 0,22 Q3.5,26 7,22" fill="none" stroke="{EYE}" stroke-width="2.2" stroke-linecap="round"/>'
        )
    g.append(
        f'<ellipse cx="-38" cy="22" rx="7.5" ry="4.5" fill="{PINK}" opacity=".75"/><ellipse cx="38" cy="22" rx="7.5" ry="4.5" fill="{PINK}" opacity=".75"/>'
    )
    g.append("</g></g>")
    return "".join(g)


def tail(d, cls="tail"):
    return f'<g class="{cls}"><path d="{d}" fill="none" stroke="{OUT}" stroke-width="32" stroke-linecap="round"/><path d="{d}" fill="none" stroke="{FUR}" stroke-width="26" stroke-linecap="round"/><path d="{d}" fill="none" stroke="{RING}" stroke-width="26" stroke-dasharray="11 15" stroke-dashoffset="4"/><path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="4" stroke-dasharray="2 24" stroke-linecap="round" opacity=".35" transform="translate(-4,-4)"/></g>'


def body(cx, cy, rx=38, ry=33):
    return f'<path d="{fluffy(rx, ry, [(200, 340)], 6, 10)}" transform="translate({cx},{cy})" fill="{FUR}" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><ellipse cx="{cx}" cy="{cy + 9}" rx="{rx * 0.58:.0f}" ry="{ry * 0.6:.0f}" fill="{DARK}"/><ellipse cx="{cx}" cy="{cy - ry + 10}" rx="{rx * 0.7:.0f}" ry="9" fill="{SHADE}" opacity=".35"/>'


def feet(cx, cy):
    return "".join(
        (
            f'<ellipse cx="{cx + dx}" cy="{cy}" rx="14.5" ry="9.5" fill="{DARK}" stroke="{OUT}" stroke-width="3"/><path d="M{cx + dx - 6},{cy - 3} L{cx + dx - 6},{cy + 2} M{cx + dx},{cy - 4} L{cx + dx},{cy + 2} M{cx + dx + 6},{cy - 3} L{cx + dx + 6},{cy + 2}" stroke="{OUT}" stroke-width="1.6" stroke-linecap="round" opacity=".55"/>'
            for dx in (-19, 19)
        )
    )


def arm(x, y, rot, ry=15, beans=False):
    s = f'<ellipse cx="{x}" cy="{y}" rx="10" ry="{ry}" transform="rotate({rot} {x} {y})" fill="{DARK}" stroke="{OUT}" stroke-width="3"/>'
    if beans:
        s += f'<g transform="rotate({rot} {x} {y})"><circle cx="{x}" cy="{y - ry + 7}" r="3.2" fill="{PINK}"/><circle cx="{x - 4.5}" cy="{y - ry + 2.5}" r="1.7" fill="{PINK}"/><circle cx="{x}" cy="{y - ry + 1}" r="1.7" fill="{PINK}"/><circle cx="{x + 4.5}" cy="{y - ry + 2.5}" r="1.7" fill="{PINK}"/></g>'
    return s


def shadow(cx, cy, rx=60, cls=""):
    return f'<ellipse class="{cls}" cx="{cx}" cy="{cy}" rx="{rx}" ry="7" fill="{OUT}" opacity=".12"/>'


def star(x, y, r, col="#F2B640", cls="twinkle"):
    return f'<g class="{cls}"><path d="M{x},{y - r} Q{x + r * 0.22},{y - r * 0.22} {x + r},{y} Q{x + r * 0.22},{y + r * 0.22} {x},{y + r} Q{x - r * 0.22},{y + r * 0.22} {x - r},{y} Q{x - r * 0.22},{y - r * 0.22} {x},{y - r} Z" fill="{col}"/></g>'


def heart(x, y, cls):
    return f'<g class="{cls}"><path d="M{x},{y + 6} C{x - 10},{y - 1} {x - 6},{y - 10} {x},{y - 4} C{x + 6},{y - 10} {x + 10},{y - 1} {x},{y + 6} Z" fill="{PINK}" stroke="{OUT}" stroke-width="1.6"/></g>'


def pose_read():
    cx, cy = (120, 150)
    book = f'<g transform="translate({cx},{cy + 2})"><path d="M-33,-14 L0,-8 L0,20 L-33,14 Z" fill="#FFFFFF" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/><g class="page"><path d="M33,-14 L0,-8 L0,20 L33,14 Z" fill="#EEF2FF" stroke="{OUT}" stroke-width="3" stroke-linejoin="round"/></g><path d="M-26,-5 L-7,-2 M-26,2 L-7,5 M-26,9 L-12,11" stroke="#9AA6D8" stroke-width="2" stroke-linecap="round"/></g>'
    return svg(
        shadow(cx, 203)
        + tail(
            f"M{cx + 30},{cy + 22} C{cx + 86},{cy + 26} {cx + 92},{cy - 36} {cx + 58},{cy - 54}"
        )
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
        tail(
            f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}"
        )
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
    z = '<g class="zz"><text x="184" y="72" font-family="Fredoka, sans-serif" font-size="22" font-weight="600" fill="#8A7D76">z</text></g><g class="zz t2"><text x="202" y="50" font-family="Fredoka, sans-serif" font-size="16" font-weight="600" fill="#B3A8A2">z</text></g>'
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
        + tail(
            f"M{cx + 58},{cy - 10} C{cx + 86},{cy - 50} {cx + 64},{cy - 100} {cx + 36},{cy - 96}"
        )
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
        + tail(
            f"M{cx + 30},{cy + 18} C{cx + 80},{cy + 10} {cx + 86},{cy - 48} {cx + 56},{cy - 64}"
        )
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
        tail(
            f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}"
        )
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
        + tail(
            f"M{cx + 30},{cy + 18} C{cx + 84},{cy + 20} {cx + 92},{cy - 40} {cx + 60},{cy - 58}"
        )
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
        tail(
            f"M{cx + 30},{cy + 20} C{cx + 84},{cy + 20} {cx + 90},{cy - 40} {cx + 60},{cy - 56}"
        )
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


CSS = ".pip .tail,.pip .tail-soft,.pip .tilt,.pip .nod,.pip .watch,.pip .bob,.pip .lids,.pip .breathe,.pip .breathe-deep,.pip .puff,.pip .hop,.pip .rock,.pip .shadow-hop,.pip .wave-l,.pip .wave-r,.pip .twinkle,.pip .spin,.pip .roll,.pip .stretch,.pip .yawn,.pip .swipe,.pip .swing,.pip .page,.pip .type-l,.pip .type-r,.pip .zz,.pip .heart{transform-box:fill-box}\n.pip .tail{transform-origin:0% 100%}.pip .tail-soft{transform-origin:100% 20%}\n.pip .tilt,.pip .nod,.pip .watch,.pip .bob{transform-origin:50% 90%}\n.pip .lids{transform-origin:50% 50%;transform:scaleY(0)}\n.pip .breathe,.pip .breathe-deep,.pip .puff{transform-origin:50% 100%}\n.pip .hop,.pip .rock{transform-origin:50% 100%}.pip .shadow-hop{transform-origin:50% 50%}\n.pip .wave-l{transform-origin:80% 100%}.pip .wave-r{transform-origin:20% 100%}\n.pip .twinkle,.pip .spin,.pip .roll{transform-origin:50% 50%}\n.pip .stretch{transform-origin:100% 100%}.pip .yawn{transform-origin:50% 0%}\n.pip .swipe{transform-origin:100% 0%}.pip .swing{transform-origin:50% 0%}.pip .page{transform-origin:0% 50%}\n.pip .type-l,.pip .type-r{transform-origin:50% 0%}\n@media (prefers-reduced-motion:no-preference){\n.moving .tail{animation:nlSway 3.2s ease-in-out infinite}\n.moving .tail-soft{animation:nlSoft 4.4s ease-in-out infinite}\n.moving .lids{animation:nlBlink 5.2s infinite}\n.moving .tilt{animation:nlTilt 5.5s ease-in-out infinite}\n.moving .nod{animation:nlNod 4.4s ease-in-out infinite}\n.moving .watch{animation:nlWatch 1.4s ease-in-out infinite}\n.moving .bob{animation:nlBob 1.8s ease-in-out infinite}\n.moving .breathe{animation:nlBreathe 3.6s ease-in-out infinite}\n.moving .breathe-deep{animation:nlBreatheDeep 4.4s ease-in-out infinite}\n.moving .puff{animation:nlPuff 2.2s ease-in-out infinite}\n.moving .hop{animation:nlHop 1.1s cubic-bezier(.3,0,.4,1) infinite}\n.moving .shadow-hop{animation:nlShadow 1.1s cubic-bezier(.3,0,.4,1) infinite}\n.moving .wave-l{animation:nlWaveL .55s ease-in-out infinite alternate}\n.moving .wave-r{animation:nlWaveR .55s ease-in-out infinite alternate}\n.moving .twinkle{animation:nlTwinkle 1.8s ease-in-out infinite}\n.moving .t2{animation-delay:-.6s}.moving .t3{animation-delay:-1.2s}\n.moving .zz{animation:nlFloat 2.8s ease-in-out infinite}\n.moving .stretch{animation:nlStretch 3.4s ease-in-out infinite}\n.moving .yawn{animation:nlYawn 3.4s ease-in-out infinite}\n.moving .swipe{animation:nlSwipe 1.5s ease-in-out infinite}\n.moving .roll{animation:nlRoll 1.5s ease-in-out infinite}\n.moving .rock{animation:nlRock 2.6s ease-in-out infinite}\n.moving .heart{animation:nlRise 2.6s ease-in infinite}\n.moving .spin{animation:nlSpin 1.1s linear infinite}\n.moving .type-l{animation:nlType .36s ease-in-out infinite alternate}\n.moving .type-r{animation:nlType .36s ease-in-out infinite alternate-reverse}\n.moving .swing{animation:nlSwing 1.8s ease-in-out infinite}\n.moving .page{animation:nlPage 4.8s ease-in-out infinite}\n}\n@keyframes nlSway{0%,100%{transform:rotate(0)}50%{transform:rotate(8deg)}}\n@keyframes nlSoft{0%,100%{transform:rotate(0)}50%{transform:rotate(-3deg)}}\n@keyframes nlBlink{0%,92%,100%{transform:scaleY(0)}95%{transform:scaleY(1)}}\n@keyframes nlTilt{0%,100%{transform:rotate(0)}30%{transform:rotate(-4deg)}65%{transform:rotate(3deg)}}\n@keyframes nlNod{0%,100%{transform:translateY(0)}50%{transform:translateY(2px) rotate(-2deg)}}\n@keyframes nlWatch{0%,100%{transform:rotate(0)}35%{transform:rotate(-6deg)}}\n@keyframes nlBob{0%,100%{transform:translateY(0)}50%{transform:translateY(2.5px)}}\n@keyframes nlBreathe{0%,100%{transform:scale(1)}50%{transform:scale(1.025,1.04)}}\n@keyframes nlBreatheDeep{0%,100%{transform:scale(1)}50%{transform:scale(1.03,1.07)}}\n@keyframes nlPuff{0%,100%{transform:scale(1)}50%{transform:scale(1.05)}}\n@keyframes nlHop{0%,100%{transform:translateY(0) scale(1.04,.96)}15%{transform:translateY(0) scale(1)}50%{transform:translateY(-16px) scale(.98,1.03)}85%{transform:translateY(0) scale(1)}}\n@keyframes nlShadow{0%,100%{transform:scale(1);opacity:.12}50%{transform:scale(.72);opacity:.07}}\n@keyframes nlWaveL{from{transform:rotate(-8deg)}to{transform:rotate(10deg)}}\n@keyframes nlWaveR{from{transform:rotate(8deg)}to{transform:rotate(-10deg)}}\n@keyframes nlTwinkle{0%,100%{transform:scale(.6);opacity:.4}50%{transform:scale(1.15);opacity:1}}\n@keyframes nlFloat{0%{transform:translate(0,0);opacity:0}25%{opacity:1}100%{transform:translate(6px,-16px);opacity:0}}\n@keyframes nlStretch{0%,100%{transform:scaleX(1)}50%{transform:scaleX(1.05) translateY(2px)}}\n@keyframes nlYawn{0%,20%,100%{transform:scaleY(.35)}50%,70%{transform:scaleY(1.1)}}\n@keyframes nlSwipe{0%,100%{transform:rotate(0)}30%{transform:rotate(-22deg)}45%{transform:rotate(4deg)}}\n@keyframes nlRoll{0%,28%,100%{transform:translateX(0) rotate(0)}55%{transform:translateX(-7px) rotate(-40deg)}}\n@keyframes nlRock{0%,100%{transform:rotate(-3deg)}50%{transform:rotate(3deg)}}\n@keyframes nlRise{0%{transform:translateY(8px) scale(.6);opacity:0}30%{opacity:1}100%{transform:translateY(-22px) scale(1);opacity:0}}\n@keyframes nlSpin{to{transform:rotate(360deg)}}\n@keyframes nlType{from{transform:translateY(0)}to{transform:translateY(-3px)}}\n@keyframes nlSwing{0%,100%{transform:rotate(-9deg)}50%{transform:rotate(9deg)}}\n@keyframes nlPage{0%,70%,100%{transform:scaleX(1)}80%{transform:scaleX(.2)}90%{transform:scaleX(1)}}"

POSES = {
    "read": pose_read,
    "hop": pose_happy,
    "nap": pose_nap,
    "stretch": pose_stretch,
    "play": pose_play,
    "hug": pose_hug,
    "study": pose_focus,
    "proud": pose_proud,
}
OUTPUTS = ("pipeline/site/pip-poses.js", "apple/App/Resources/pip-poses.js")


def build_js() -> str:
    poses = {
        name: draw().replace('width="100%" height="100%"', 'width="100%"')
        for name, draw in POSES.items()
    }
    poses["icon"] = (
        f'<svg viewBox="-64 -68 128 122" width="100%" aria-hidden="true">{head(0, 0, 1, "happy", cls="tilt")}</svg>'
    )
    return f"window.PIP={json.dumps(poses)};\nwindow.PIP_CSS={json.dumps(CSS)};\n"


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    js = build_js()
    for relative in OUTPUTS:
        (root / relative).write_text(js, encoding="utf-8")
        print(f"wrote {relative}")


if __name__ == "__main__":
    main()
