"""The README's pictures: a hero banner (light and dark), a cute animated demo of a whole learning loop, and Pip's poses.

Run `python design/readme/make_readme_art.py` from the repo root (needs Playwright's Chromium from `make setup`, and
ffmpeg for the GIF: `brew install ffmpeg`). Writes docs/readme/*.png and docs/readme/demo.gif. Never edit them by hand.

The demo is a storyboard drawn in the app's style with Pip's real artwork (not screenshots of anyone's library), rendered
frame by frame: every Pip animation and every moving part is set from the frame's time, so the GIF is deterministic.
"""

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "design" / "pip"))
from generate_pip import CSS, POSES  # noqa: E402

OUT = ROOT / "docs" / "readme"
FONTS = ROOT / "pipeline" / "neuralloop_books" / "assets" / "fonts"
SCENE = 3.2  # seconds per demo scene
SCENES = 7
FPS = 12
DEMO_SIZE = (800, 480)


def font(family: str, weight: int, file: str) -> str:
    data = base64.b64encode((FONTS / file).read_bytes()).decode()
    return f"@font-face{{font-family:'{family}';font-weight:{weight};src:url(data:font/woff2;base64,{data}) format('woff2')}}"


FONT_CSS = (
    font("Fredoka", 600, "fredoka-600.woff2")
    + font("Fredoka", 500, "fredoka-500.woff2")
    + font("Atkinson", 400, "atkinson-400.woff2")
    + font("Atkinson", 700, "atkinson-700.woff2")
)

BASE_CSS = f"""
{FONT_CSS}
{CSS}
*{{box-sizing:border-box}}
html,body{{margin:0;overflow:hidden}}
body{{font-family:Atkinson,-apple-system,sans-serif;color:#35251F}}
.display{{font-family:Fredoka,sans-serif;font-weight:600}}
"""


def pip(pose: str, width: int, extra: str = "") -> str:
    return f'<div class="pip moving" style="width:{width}px;{extra}">{POSES[pose]()}</div>'


# MARK: hero


def hero(dark: bool) -> str:
    paper, ink, ink2 = ("#1D1716", "#FBEFEA", "#CDB9B1") if dark else ("#FFF7F2", "#35251F", "#6E5A52")
    blobs = (
        ("#4A2B20", "#3E331A", "#1F3A33", "#23304D") if dark else ("#FDE3D7", "#FCEFCF", "#DDF3EA", "#E3ECFF")
    )
    chip = "#2A2220" if dark else "#FFFFFF"
    steps = [("🎧", "Listen"), ("📖", "Read"), ("💬", "Recall"), ("🗺️", "Map"), ("🃏", "Remember")]
    chips = "".join(f'<span class="chip">{e} {w}</span>' for e, w in steps)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body{{width:1280px;height:440px;background:{paper};position:relative}}
.blob{{position:absolute;border-radius:50%;filter:blur(6px)}}
h1{{position:absolute;left:470px;top:70px;margin:0;font-size:104px;color:{ink};letter-spacing:-1px}}
h1 span{{color:#E0683F}}
.tag{{position:absolute;left:476px;top:210px;width:720px;font-size:27px;line-height:1.4;color:{ink2}}}
.chips{{position:absolute;left:470px;top:318px;display:flex;gap:12px}}
.chip{{background:{chip};border-radius:999px;padding:10px 18px;font-family:Fredoka;font-weight:500;font-size:21px;color:{ink};
      box-shadow:0 4px 14px rgba(224,104,63,.14)}}
</style></head><body>
<div class="blob" style="width:420px;height:420px;left:-120px;top:-150px;background:{blobs[0]}"></div>
<div class="blob" style="width:300px;height:300px;right:-80px;top:-110px;background:{blobs[1]}"></div>
<div class="blob" style="width:340px;height:340px;right:120px;bottom:-230px;background:{blobs[2]}"></div>
<div class="blob" style="width:240px;height:240px;left:300px;bottom:-190px;background:{blobs[3]}"></div>
{pip("hop", 380, "position:absolute;left:60px;top:40px")}
<h1 class="display">Neural<span>Loop</span></h1>
<div class="tag">Turn any book you own into tiny learning loops, with <b>Pip</b>, a red panda who studies with you.</div>
<div class="chips">{chips}</div>
</body></html>"""


# MARK: poses


def poses_strip() -> str:
    names = {
        "read": "reading",
        "hop": "happy hop",
        "study": "preparing",
        "play": "playing",
        "hug": "loop closed",
        "proud": "proud",
        "stretch": "welcome back",
        "nap": "napping",
    }
    cells = "".join(
        f'<div class="cell">{pip(p, 150)}<div class="label">{label}</div></div>' for p, label in names.items()
    )
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body{{width:1360px;height:230px;background:transparent;display:flex;gap:10px;padding:10px 20px}}
.cell{{width:160px;display:flex;flex-direction:column;align-items:center}}
.label{{font-family:Fredoka;font-weight:500;font-size:18px;color:#9A867E;margin-top:4px}}
</style></head><body>{cells}</body></html>"""


def single_pose(pose: str) -> str:
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body{{width:240px;height:220px;background:transparent}}</style></head><body>{pip(pose, 240)}</body></html>"""


# MARK: demo


def demo() -> str:
    w, h = DEMO_SIZE
    chapters = ["What is a cache?", "Hits and misses", "Invalidation", "Eviction", "Caches at scale"]
    items = ["🎧", "🎬", "📖", "💬", "🗺️", "🃏"]
    rows = "".join(
        f'<div class="row"><span class="n">{i + 1}</span><span class="ct">{c}</span>'
        + "".join(f'<span class="it" data-k="{i * 6 + j}">{e}</span>' for j, e in enumerate(items))
        + "</div>"
        for i, c in enumerate(chapters)
    )
    bars = "".join(f'<i data-b="{i}"></i>' for i in range(34))
    nodes = [
        ("Cache", 300, 150, "#E0683F", 26),
        ("Hit", 170, 90, "#3FA88A", 18),
        ("Miss", 180, 225, "#E2577E", 18),
        ("TTL", 430, 85, "#5C86E0", 16),
        ("Eviction", 450, 215, "#5C86E0", 18),
        ("LRU", 560, 150, "#9A6FD6", 15),
        ("Latency", 300, 280, "#D9A21B", 16),
    ]
    edges = [(0, 1), (0, 2), (0, 3), (0, 4), (4, 5), (0, 6), (2, 6)]
    node_html = "".join(
        f'<div class="node" data-n="{i}" style="left:{x}px;top:{y}px"><b style="width:{r * 2}px;height:{r * 2}px;'
        f'background:{c}"></b><span>{name}</span></div>'
        for i, (name, x, y, c, r) in enumerate(nodes)
    )
    edge_svg = "".join(
        f'<line data-e="{k}" x1="{nodes[a][1]}" y1="{nodes[a][2]}" x2="{nodes[b][1]}" y2="{nodes[b][2]}"/>'
        for k, (a, b) in enumerate(edges)
    )
    confetti = "".join(
        f'<i data-c="{i}" style="background:{["#E0683F", "#3FA88A", "#5C86E0", "#F2B640", "#E2577E"][i % 5]}"></i>'
        for i in range(36)
    )
    heat = "".join(f'<i data-h="{i}"></i>' for i in range(26 * 7))
    sprout = "".join(
        f'<b data-sp="{i}" style="background:{["#E0683F", "#3FA88A", "#5C86E0", "#E2577E", "#9A6FD6"][i % 5]}"></b>'
        for i in range(22)
    )
    labels = [
        "Drop in a book",
        "Pip prepares it",
        "Listen & watch",
        "Read · Recall",
        "Map",
        "Remember",
        "Watch it grow",
    ]
    dots = "".join(f'<i data-d="{i}"></i>' for i in range(SCENES))

    def scene(i: int, body: str, pose: str, say: str) -> str:
        step = {2: "1", 3: "2·3", 4: "4", 5: "5"}.get(i, "")
        tag = f'<span class="num">{step}</span>' if step else "✨"
        return f"""<section data-s="{i}">
  <div class="chipstep display">{tag} {labels[i]}</div>
  <div class="win"><div class="bar"><i></i><i></i><i></i><span>NeuralLoop</span></div><div class="body">{body}</div></div>
  <div class="pipbox">{pip(pose, 170)}<div class="bubble">{say}</div></div>
</section>"""

    s0 = """<div class="shelf">
  <div class="cover" style="background:linear-gradient(135deg,#DDF3EA,#9ad6c3)"><span>Systems 101</span></div>
  <div class="cover" style="background:linear-gradient(135deg,#E3ECFF,#a9bff0)"><span>Tiny Habits of Code</span></div>
  <div class="cover drop" id="dropped" style="background:linear-gradient(135deg,#FDE3D7,#f0a987)"><span>The Curious Coder</span>
     <em id="prep">⏳ Pip is preparing…</em></div>
  <div class="dz" id="dz">＋ drop a PDF or EPUB</div>
</div>"""
    s1 = f"""<div class="chap">{rows}</div><div class="toast" id="toast">🔔 <b>Chapter 1 is ready to study</b><br>
<span>“What is a cache?” · Pip saved you a spot</span></div>"""
    s2 = f"""<div class="listen"><div class="video"><div class="vpip">{pip("read", 120)}</div>
  <div class="vcap">Pip explains: what is a cache?</div><div class="vprog"><b id="vprog"></b></div></div>
  <div class="pod"><div class="play">❚❚</div><div class="wave">{bars}</div></div>
  <div class="line"><b style="color:#E0683F">Aisha</b> So what is a cache, really?</div>
  <div class="line" id="l2"><b style="color:#5C86E0">Siya</b> A little shelf right next to you, so you don't walk to the library.</div></div>"""
    s3 = """<div class="recall"><div class="q display">Explain a cache in your own words</div>
  <div class="ans" id="ans"></div>
  <div class="kps"><div class="kp" data-p="0">✔ keeps a copy close</div><div class="kp" data-p="1">✔ reads get faster</div>
  <div class="kp" data-p="2">✔ copies can go stale</div></div>
  <div class="stars" id="stars">★ ★ ★ <span>you explained it fully!</span></div></div>"""
    s4 = f"""<div class="graph"><svg width="640" height="320">{edge_svg}</svg>{node_html}</div>"""
    s5 = f"""<div class="cards"><div class="card" id="card"><div class="face front display">What's a cache hit?</div>
  <div class="face back display">When the thing you need is already in the cache 🎯</div></div>
  <div class="rate"><span>Again</span><span>Hard</span><span id="good">Good</span><span>Easy</span></div>
  <div class="closed display" id="closed">Loop closed! 🎉</div><div class="conf">{confetti}</div></div>"""
    s6 = f"""<div class="grow"><div class="map">{sprout}<div class="mapt display">Your book map</div></div>
  <div class="year"><div class="yt display">Your year with Pip</div><div class="heat">{heat}</div></div>
  <div class="end display" id="end">Learn it. Loop it. 🐾</div></div>"""

    sections = [
        scene(0, s0, "hug", "Ooh, a new book!"),
        scene(1, s1, "study", "Making podcasts, quizzes<br>and maps for you…"),
        scene(2, s2, "read", "Hear it first. It'll feel<br>familiar when you read."),
        scene(3, s3, "hop", "Look at you go!"),
        scene(4, s4, "play", "Every idea, connected."),
        scene(5, s5, "proud", "Right before you'd forget."),
        scene(6, s6, "hug", "One loop at a time."),
    ]
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
*{{animation-play-state:paused!important}}
body{{width:{w}px;height:{h}px;background:linear-gradient(135deg,#FFF7F2,#FCEFCF);position:relative}}
section{{position:absolute;inset:0;opacity:0}}
.chipstep{{position:absolute;left:28px;top:18px;font-size:22px;color:#35251F;display:flex;align-items:center;gap:8px}}
.num{{display:inline-flex;min-width:30px;padding:0 8px;height:30px;border-radius:999px;background:#E0683F;color:#fff;align-items:center;
     justify-content:center;font-size:17px}}
.win{{position:absolute;left:24px;top:60px;width:560px;height:370px;background:#fff;border-radius:18px;
     box-shadow:0 12px 40px rgba(53,37,31,.12);overflow:hidden}}
.bar{{height:34px;background:#F6EEE9;display:flex;align-items:center;gap:7px;padding:0 14px}}
.bar i{{width:11px;height:11px;border-radius:50%;background:#F26B5E}}.bar i:nth-child(2){{background:#F5BE4F}}
.bar i:nth-child(3){{background:#5FC454}}.bar span{{margin-left:10px;font-family:Fredoka;font-weight:500;color:#A08E86;font-size:14px}}
.body{{position:absolute;top:34px;left:0;right:0;bottom:0;padding:18px}}
.pipbox{{position:absolute;right:18px;bottom:40px;width:190px;display:flex;flex-direction:column;align-items:center}}
.bubble{{order:-1;background:#fff;border-radius:16px;padding:10px 14px;font-size:15px;line-height:1.35;text-align:center;
        box-shadow:0 6px 18px rgba(224,104,63,.16);margin-bottom:8px;font-family:Fredoka;font-weight:500}}
.dots{{position:absolute;left:0;right:0;bottom:12px;display:flex;justify-content:center;gap:8px}}
.dots i{{width:9px;height:9px;border-radius:50%;background:#EBD9CF}}
/* 0 shelf */
.shelf{{display:grid;grid-template-columns:repeat(2,1fr);gap:16px}}
.cover{{height:128px;border-radius:14px;position:relative;padding:14px;display:flex;align-items:flex-end}}
.cover span{{font-family:Fredoka;font-weight:600;font-size:19px;color:#35251F}}
.cover em{{position:absolute;top:12px;left:14px;font-style:normal;font-size:13px;color:#6E5A52;opacity:0}}
.dz{{height:128px;border-radius:14px;border:2px dashed #E7CDBF;display:flex;align-items:center;justify-content:center;
    color:#A08E86;font-family:Fredoka;font-weight:500}}
/* 1 chapters */
.row{{display:flex;align-items:center;gap:8px;padding:9px 6px;border-bottom:1px solid #F4E6DE}}
.row .n{{width:24px;height:24px;border-radius:50%;background:#FDE3D7;color:#E0683F;display:flex;align-items:center;
        justify-content:center;font-family:Fredoka;font-weight:600;font-size:13px}}
.row .ct{{flex:1;font-size:15px}}.it{{font-size:17px;filter:grayscale(1);opacity:.28}}
.toast{{position:absolute;right:14px;top:12px;background:#35251F;color:#FBEFEA;border-radius:14px;padding:10px 14px;font-size:13px;
       line-height:1.4;box-shadow:0 10px 30px rgba(0,0,0,.2);opacity:0}}.toast span{{color:#CDB9B1}}
/* 2 listen */
.video{{height:150px;border-radius:14px;background:linear-gradient(135deg,#FFF4E6,#FDE3D7);position:relative;overflow:hidden}}
.vpip{{position:absolute;left:24px;top:14px}}.vcap{{position:absolute;left:170px;top:52px;font-family:Fredoka;font-weight:600;
      font-size:20px;width:320px}}
.vprog{{position:absolute;left:0;right:0;bottom:0;height:6px;background:#F3D7C9}}.vprog b{{display:block;height:6px;background:#E0683F}}
.pod{{display:flex;align-items:center;gap:14px;margin:16px 0 10px}}
.play{{width:40px;height:40px;border-radius:50%;background:#E0683F;color:#fff;display:flex;align-items:center;justify-content:center;
      font-size:13px}}
.wave{{display:flex;align-items:center;gap:4px;height:44px}}.wave i{{width:6px;border-radius:3px;background:#E0683F;opacity:.75}}
.line{{font-size:14px;padding:6px 10px;border-radius:10px;margin-bottom:5px}}.line b{{margin-right:8px;font-family:Fredoka}}
/* 3 recall */
.q{{font-size:21px;margin-bottom:10px}}
.ans{{min-height:84px;border:1.5px solid #F1DDD3;border-radius:12px;padding:10px 12px;font-size:16px;line-height:1.45}}
.kps{{margin-top:12px;display:flex;flex-direction:column;gap:6px}}
.kp{{font-size:15px;color:#3FA88A;background:#DDF3EA;border-radius:10px;padding:6px 10px;opacity:0}}
.stars{{margin-top:10px;color:#F2B640;font-size:22px;opacity:0}}.stars span{{font-size:14px;color:#6E5A52;margin-left:6px}}
/* 4 graph */
.graph{{position:relative;width:640px;height:320px;margin-left:-40px}}.graph svg{{position:absolute;left:0;top:0}}
.graph line{{stroke:#C9B6AD;stroke-width:2;stroke-dasharray:400;stroke-dashoffset:400}}
.node{{position:absolute;transform:translate(-50%,-50%) scale(0);display:flex;flex-direction:column;align-items:center}}
.node b{{border-radius:50%;box-shadow:0 4px 10px rgba(0,0,0,.12)}}.node span{{font-size:13px;margin-top:3px;font-weight:700}}
/* 5 cards */
.cards{{position:relative;height:100%;perspective:900px}}
.card{{position:relative;width:360px;height:170px;margin:6px auto 0;transform-style:preserve-3d}}
.face{{position:absolute;inset:0;border-radius:18px;display:flex;align-items:center;justify-content:center;text-align:center;
      padding:20px;font-size:23px;backface-visibility:hidden}}
.front{{background:#FCEFCF}}.back{{background:#DDF3EA;transform:rotateY(180deg);font-size:20px}}
.rate{{display:flex;justify-content:center;gap:10px;margin-top:22px}}
.rate span{{padding:8px 14px;border-radius:10px;border:1.5px solid #F1DDD3;font-family:Fredoka;font-weight:500}}
#good.on{{background:#3FA88A;color:#fff;border-color:#3FA88A}}
.closed{{position:absolute;left:0;right:0;top:250px;text-align:center;font-size:30px;color:#E0683F;opacity:0}}
.conf i{{position:absolute;width:8px;height:12px;border-radius:2px;opacity:0}}
/* 6 grow */
.grow{{position:relative;height:100%}}.map{{position:relative;height:170px}}
.map b{{position:absolute;width:14px;height:14px;border-radius:50%;transform:scale(0)}}
.mapt,.yt{{position:absolute;left:0;top:0;font-size:17px;color:#6E5A52}}
.year{{position:relative;margin-top:8px}}.yt{{position:static;margin-bottom:6px}}
.heat{{display:grid;grid-template-columns:repeat(26,1fr);grid-auto-flow:column;grid-template-rows:repeat(7,1fr);gap:3px;width:500px}}
.heat i{{height:13px;border-radius:3px;background:#F4E6DE}}
.end{{position:absolute;left:50%;top:52%;transform:translate(-50%,-50%);white-space:nowrap;font-size:30px;color:#E0683F;
     background:rgba(255,255,255,.96);padding:14px 30px;border-radius:999px;box-shadow:0 12px 36px rgba(224,104,63,.25);opacity:0}}
</style></head><body>
{"".join(sections)}
<div class="dots">{dots}</div>
<script>
const SCENE={SCENE}, N={SCENES};
const $=(s,r=document)=>r.querySelector(s), $$=(s,r=document)=>[...r.querySelectorAll(s)];
const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)), ease=x=>x<.5?2*x*x:1-Math.pow(-2*x+2,2)/2;
const span=(p,a,b)=>clamp((p-a)/(b-a));
const back=x=>{{const c=1.7;return 1+(c+1)*Math.pow(x-1,3)+c*Math.pow(x-1,2);}};
function renderAt(t){{
  document.getAnimations().forEach(a=>{{a.currentTime=(t*1000)%(1e7);}});
  const i=Math.min(N-1,Math.floor(t/SCENE)), p=(t-i*SCENE)/SCENE;
  $$('section').forEach((s,k)=>{{const fadeIn=k===i?span(p,0,.08):0, fadeOut=k===i&&i<N-1?1-span(p,.94,1):1;
    s.style.opacity=k===i?Math.min(fadeIn,fadeOut):0;}});
  $$('[data-d]').forEach((d,k)=>d.style.background=k===i?'#E0683F':(k<i?'#F3B89F':'#EBD9CF'));
  if(i===0){{const d=$('#dropped'), q=back(span(p,.12,.42));
    d.style.transform=`translateY(${{(1-q)*-260}}px) rotate(${{(1-q)*-8}}deg)`; d.style.opacity=span(p,.1,.16);
    $('#dz').style.opacity=1-span(p,.12,.3); $('#prep').style.opacity=span(p,.5,.6);}}
  if(i===1){{$$('[data-k]').forEach(e=>{{const k=+e.dataset.k, on=span(p,.05+k*0.022,.08+k*0.022);
      e.style.filter=`grayscale(${{1-on}})`; e.style.opacity=.28+on*.72;}});
    const tp=span(p,.42,.52); $('#toast').style.opacity=tp; $('#toast').style.transform=`translateY(${{(1-tp)*-16}}px)`;}}
  if(i===2){{$('#vprog').style.width=(p*100)+'%';
    $$('[data-b]').forEach(b=>{{const k=+b.dataset.b; b.style.height=(8+Math.abs(Math.sin(t*6+k*.7))*30*(.5+.5*Math.sin(k*1.3)))+'px';}});
    $('#l2').style.background=p>.5?'#FDE3D7':'transparent';}}
  if(i===3){{const txt='A cache keeps a copy of data close by, so reads are fast, but the copy can go stale.';
    $('#ans').textContent=txt.slice(0,Math.round(txt.length*span(p,.05,.55)))+(p<.55&&Math.floor(t*3)%2?'|':'');
    $$('[data-p]').forEach(k=>k.style.opacity=span(p,.58+(+k.dataset.p)*.08,.64+(+k.dataset.p)*.08));
    $('#stars').style.opacity=span(p,.84,.9);}}
  if(i===4){{$$('[data-n]').forEach(n=>{{const k=+n.dataset.n, s=back(span(p,.06+k*.08,.16+k*.08));
      n.style.transform=`translate(-50%,-50%) scale(${{s}})`;}});
    $$('[data-e]').forEach(e=>{{const k=+e.dataset.e; e.style.strokeDashoffset=400*(1-span(p,.2+k*.07,.34+k*.07));}});}}
  if(i===5){{const f=ease(span(p,.25,.45)); $('#card').style.transform=`rotateY(${{f*180}}deg)`;
    $('#good').classList.toggle('on',p>.58); const c=span(p,.68,.76); $('#closed').style.opacity=c;
    $('#closed').style.transform=`scale(${{.7+.3*back(c)}})`;
    $$('[data-c]').forEach(e=>{{const k=+e.dataset.c, q=span(p,.68,1), a=k*2.4, v=120+(k%7)*22;
      e.style.left=(270+Math.cos(a)*v*q)+'px'; e.style.top=(265+Math.sin(a)*v*q*.8+q*q*120)+'px';
      e.style.opacity=q>0&&q<1?1-q*.6:0; e.style.transform=`rotate(${{k*40+q*300}}deg)`;}});}}
  if(i===6){{$$('[data-sp]').forEach(b=>{{const k=+b.dataset.sp, a=k*2.39996, r=16*Math.sqrt(k)*2.2;
      b.style.left=(250+Math.cos(a)*r)+'px'; b.style.top=(92+Math.sin(a)*r*.62)+'px';
      b.style.transform=`scale(${{back(span(p,.04+k*.022,.1+k*.022))}})`;}});
    const greens=['#F4E6DE','#DDF3EA','#9fd9c4','#6fc4a7','#3FA88A'];
    $$('[data-h]').forEach(h=>{{const k=+h.dataset.h, on=span(p,.3+k*.0022,.33+k*.0022); const lvl=((k*37)%11)%5;
      h.style.background=on>0?greens[Math.max(1,Math.round(lvl*on))]:greens[0];}});
    $('#end').style.opacity=span(p,.78,.88);}}
}}
window.renderAt=renderAt;
</script></body></html>"""


# MARK: rendering


def main() -> None:
    from playwright.sync_api import sync_playwright

    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p, tempfile.TemporaryDirectory() as tmp:
        browser = p.chromium.launch()
        for dark in (False, True):
            page = browser.new_page(viewport={"width": 1280, "height": 440}, device_scale_factor=2)
            page.set_content(hero(dark), wait_until="load")
            page.evaluate("document.fonts.ready")
            page.evaluate("document.getAnimations().forEach(a => a.pause())")
            page.screenshot(path=str(OUT / ("hero-dark.png" if dark else "hero.png")))
            page.close()
        page = browser.new_page(viewport={"width": 1360, "height": 230}, device_scale_factor=2)
        page.set_content(poses_strip(), wait_until="load")
        page.evaluate("document.getAnimations().forEach(a => a.pause())")
        page.screenshot(path=str(OUT / "poses.png"), omit_background=True)
        page.close()
        for pose in POSES:
            page = browser.new_page(viewport={"width": 240, "height": 220}, device_scale_factor=2)
            page.set_content(single_pose(pose), wait_until="load")
            page.evaluate("document.getAnimations().forEach(a => a.pause())")
            page.screenshot(path=str(OUT / f"pip-{pose}.png"), omit_background=True)
            page.close()

        w, h = DEMO_SIZE
        page = browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
        page.set_content(demo(), wait_until="load")
        page.evaluate("document.fonts.ready")
        frames = Path(tmp)
        total = int(SCENE * SCENES * FPS)
        for n in range(total):
            page.evaluate(f"renderAt({n / FPS})")
            page.screenshot(path=str(frames / f"f{n:04d}.png"))
        browser.close()
        # A palette made for these frames keeps Pip's colours clean in the GIF.
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(frames / "f%04d.png"),
             "-vf", "split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
             "-loop", "0", str(OUT / "demo.gif")],
            check=True,
        )  # fmt: skip
    for f in sorted(OUT.iterdir()):
        print(f"wrote {f.relative_to(ROOT)} ({f.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
