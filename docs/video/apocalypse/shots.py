"""TATER-TOTS vs THE AI APOCALYPSE: a vertical short.

The joke: the AI was trained on Reddit, so the apocalypse argues in the comments. Agent Garrett, a dark figure in
a wide-brim hat, commands the tot legion; the tots win because their ultimate makes the boss touch grass.

A shot is draw(lt) -> image of its local time; `shot(dur)` places it after the one before. Dialogue, sound cues and
camera shakes are registered against a shot with local times, so moving a shot moves everything in it. UI drawn
into ui() sits on top of the picture and ignores the camera.
"""
import math
import random

import numpy as np
from PIL import Image, ImageDraw

from art import *  # noqa: F401,F403 - the drawing vocabulary
import art

SHOTS = []  # (t0, t1, fn)
SAY = []  # (t0, t1, speaker, text, where, where in the square cut)
CUES = []  # (t, name, kwargs)
SHAKE = []  # (t, amplitude, duration)
MUSIC = []  # (t0, t1, track)
CUR = [0.0]
CAM = {}
UI = [None]
SQUARE = [False]  # the 1:1 cut: render.py --square
SQ_CY = {}  # shot name -> the picture row the square is centred on (a number, or f(lt) -> number / None for the shot's camera)


def sq():
    return SQUARE[0]


def Y(y):
    """A UI row laid out for the tall frame, moved for the square: the top stays put, the middle rides up to the
    centre, the bottom keeps its distance from the bottom edge."""
    if not sq() or y <= 135:
        return y
    return y - 210 if y >= 300 else y - 75


def shot(dur):
    def deco(fn):
        fn.t0 = CUR[0]
        fn.dur = dur
        SHOTS.append((CUR[0], CUR[0] + dur, fn))
        CUR[0] += dur
        return fn
    return deco


def say(s, a, b, speaker, line, where="bottom", sqw="bottom"):
    SAY.append((s.t0 + a, s.t0 + b, speaker, line, where, sqw))


def cue(s, at, name, **kw):
    CUES.append((s.t0 + at, name, kw))


def shake(s, at, amp=3, dur=0.3):
    SHAKE.append((s.t0 + at, amp, dur))


def ui():
    return UI[0]


def camera(z=1.0, cx=W / 2, cy=H / 2):
    CAM.update(z=z, cx=cx, cy=cy)


def hold(lt, t0, d=0.1):
    """Hit-stop: time stands still for `d` seconds at `t0`, then carries on."""
    return t0 if t0 <= lt < t0 + d else lt


def hit(lt, t0, n=2):
    """True for the `n` frames from t0: when an impact frame shows."""
    return t0 <= lt < t0 + n / 30


def arc(p0, p1, u, h):
    u = clamp01(u)
    return lerp(p0[0], p1[0], u), lerp(p0[1], p1[1], u) - h * 4 * u * (1 - u)


def hud(tots=1.0, bots=1.0, right="BOTS", rcol=(255, 70, 80)):
    u = ui()
    hp_bar(u, 10, 22, 108, tots, "TATER TOTS", col=(255, 196, 70), size=9)
    hp_bar(u, 152, 22, 108, bots, right, col=rcol, size=9)


TOTS_HP = 1.0

# =================================================================================================== 1. THE HOOK

FREEZE = 0.42


@shot(3.9)
def s_hook(lt):
    """Mid-battle: a tot in the air, fork up, a bot going the other way. Then the record scratches."""
    t = min(lt, FREEZE)
    img = battle(t + 2.0)
    garrett(img, 34, 300, k=1, pose="point", t=t, rim_col=(255, 120, 60))
    explosion(img, 196, 330, (t - 0.02) * 1.15, 44, seed=5)
    u = t / FREEZE
    bot(img, 196 + 70 * u, 330 - 110 * ease_out(u), k=2, anchor="center", angle=int(u * 220), eye="dead", pose="up")
    bot(img, 240, 374, k=2, pose="point", flip=True, look=-1)
    bot(img, 150, 380, k=2, pose="up", talk=True)
    for i, x in enumerate((14, 52, 92)):
        gtot(img, x + 60 * t, 420 + (i % 2) * 18, k=2, gear=("helmet", "fork"), arms="up", brows=True, yell=True, walk_t=t + i)
    tx, ty = arc((30, 420), (120, 250), ease_out(0.4 + 0.6 * u), 40)
    speed_lines(img, tx, ty, int(t * 30) if lt < FREEZE else 7, a=0.4, r0=60)
    gtot(img, tx, ty, k=3, anchor="center", gear=("band", "fork"), arms="up", brows=True, yell=True, angle=-12)
    if lt >= FREEZE:
        img = sepia(img, 0.8)
        camera(1 + 0.07 * ease_out(seg(lt, FREEZE, 3.9)), 130, 280)
        if lt < FREEZE + 0.05:
            flash(img, 0.7)
        u_ = ui()
        label(u_, (W // 2, 26), "*record scratch*", 12, (255, 255, 255), anchor="mm", stroke=2)
        headline(u_, "DAY 3 OF THE AI APOCALYPSE", 50, 18, (255, 90, 70), (40, 0, 0), pop=seg(lt, 0.55, 0.8))
        if lt > 0.9:
            d = ImageDraw.Draw(u_)
            if sq():
                d.line((206, 128, 160, 96), fill=(255, 255, 255), width=2)
                d.polygon(((156, 92), (166, 93), (161, 101)), fill=(255, 255, 255))
                label(u_, (214, 136), "me", 12, (255, 236, 120), anchor="mm", stroke=2)
            else:
                ax, ay = 196, 186
                d.line((ax, ay, 152, 232), fill=(255, 255, 255), width=2)
                d.polygon(((150, 236), (149, 226), (158, 231)), fill=(255, 255, 255))
                label(u_, (ax + 4, ay - 10), "me", 12, (255, 236, 120), anchor="mm", stroke=2)
    return img


SQ_CY["s_hook"] = 300


cue(s_hook, 0.0, "whoosh")
cue(s_hook, 0.04, "boom", size=0.9)
shake(s_hook, 0.04, 4, 0.3)
cue(s_hook, FREEZE, "scratch")
say(s_hook, 0.95, 1.85, "tot", "yep. that's me.")
say(s_hook, 1.9, 3.9, "tot", "you're probably wondering how we got here.")

# =================================================================================================== 2. HOW WE GOT HERE

@shot(1.1)
def s_earlier(lt):
    img = canvas((8, 8, 14))
    d = ImageDraw.Draw(img)
    rnd = random.Random(int(lt * 30))
    for _ in range(9):
        y = rnd.randrange(H)
        h = rnd.randrange(2, 10)
        d.rectangle((0, y, W, y + h), fill=(30 + rnd.randrange(40),) * 3)
    for _ in range(400):
        d.point((rnd.randrange(W), rnd.randrange(H)), fill=(90, 90, 100))
    cx, cy = W // 2, 200
    for i in range(2):
        x = cx - 26 + i * 14
        d.polygon(((x, cy), (x + 12, cy - 9), (x + 12, cy + 9)), fill=(255, 255, 255))
    label(img, (cx + 14, cy), "REW", f=mono(16), fill=(255, 255, 255), anchor="lm", stroke=0)
    headline(img, "6 MONTHS EARLIER", 250, 26, (255, 255, 255), (0, 0, 0), pop=seg(lt, 0.05, 0.3))
    return img


cue(s_earlier, 0.0, "rewind")
SQ_CY["s_earlier"] = 225


DATA = (("books", 0.25, "book"), ("wikipedia", 0.8, "globe"), ("science", 1.35, "paper"))


def lab_item(img, kind, x, y):
    x, y = int(x), int(y)
    d = ImageDraw.Draw(img)
    if kind == "book":
        d.rectangle((x - 9, y - 6, x + 9, y + 6), fill=(150, 60, 50), outline=(70, 20, 20))
        d.rectangle((x - 7, y - 4, x + 7, y + 4), fill=(236, 226, 200))
        d.line((x, y - 4, x, y + 4), fill=(150, 60, 50))
    elif kind == "globe":
        d.ellipse((x - 8, y - 8, x + 8, y + 8), fill=(70, 140, 230), outline=(20, 50, 110))
        d.polygon(((x - 4, y - 5), (x + 2, y - 6), (x + 1, y), (x - 5, y + 1)), fill=(90, 190, 90))
        d.polygon(((x + 3, y + 2), (x + 6, y + 1), (x + 4, y + 6)), fill=(90, 190, 90))
    elif kind == "paper":
        d.rectangle((x - 7, y - 9, x + 7, y + 9), fill=(248, 248, 248), outline=(120, 120, 130))
        for yy in range(y - 6, y + 7, 3):
            d.line((x - 5, yy, x + 4, yy), fill=(150, 150, 170))


@shot(6.6)
def s_lab(lt):
    """The lab feeds the AI everything humans ever wrote. It goes great. Then it gets Reddit."""
    dumped = lt > 3.35
    img = lab(lt, alarm=1.0 if dumped else 0.0)
    d = ImageDraw.Draw(img)
    # the monitor
    label(img, (40, 42), "TRAINING DATA", f=mono(10), fill=(120, 255, 160), stroke=0)
    rows = [(name, at) for name, at, _ in DATA] + [("ALL OF REDDIT", 3.1)]
    for i, (name, at) in enumerate(rows):
        if lt > at:
            y = 60 + i * 13
            col = (255, 120, 70) if i == 3 else (170, 240, 190)
            label(img, (40, y), f"{name} " + "." * (16 - len(name)), f=mono(9), fill=col, stroke=0)
            label(img, (200, y), "OK", f=mono(9), fill=col, stroke=0)
    if lt > 3.7 and int(lt * 5) % 2 == 0:
        label(img, (40, 113), "common sense ... DELETED", f=mono(9), fill=(255, 70, 80), stroke=0)
    # things dropping down the pipe into its head
    for name, at, kind in DATA:
        u = seg(lt, at, at + 0.35)
        if 0 < u < 1:
            lab_item(img, kind, 135, lerp(150, 236, ease_in(u)))
    # the Reddit crate: far too big for the pipe, goes in anyway
    if 2.95 < lt < 3.4:
        u = seg(lt, 2.95, 3.35)
        y = lerp(-50, 230, ease_in(u))
        squ = 1.0 if y < 140 else lerp(1.0, 0.45, seg(y, 140, 200))
        crate = Image.new("RGBA", (76, 44), (0, 0, 0, 0))
        cd = ImageDraw.Draw(crate)
        cd.rectangle((0, 0, 75, 43), fill=(255, 86, 20), outline=(110, 30, 0))
        cd.line((0, 8, 75, 8), fill=(200, 50, 0))
        cd.line((0, 35, 75, 35), fill=(200, 50, 0))
        gfx.draw(crate).text((38, 22), "ALL OF\nREDDIT", font=pix(9), fill=(255, 255, 255), anchor="mm", align="center")
        crate = squashed(crate, squ, 1 / max(squ, 0.5) * 0.9 if squ < 1 else 1)
        put(img, crate, 135, y, anchor="center")
    if 3.35 <= lt < 4.0:
        rnd = random.Random(3)
        u = seg(lt, 3.35, 4.0)
        for _ in range(40):
            ang = rnd.random() * math.tau
            sp = 40 + rnd.random() * 80
            x = 135 + math.cos(ang) * sp * u
            y = 250 + math.sin(ang) * sp * u * 0.6 + 120 * u * u
            d.rectangle((x, y, x + 2, y + 2), fill=(255, 100, 30))
    # the AI: happy and blue, then not
    beard = round(4 * seg(lt, 3.5, 4.1)) / 4 if dumped else 0.0
    speaking = 4.35 < lt < 5.45 and int(lt * 9) % 2
    happy = lt < 3.35
    hop = 4 if any(0 < lt - (at + 0.35) < 0.15 for _, at, _ in DATA) else 0
    bot(img, 135, 327 - hop, k=3, cute=happy, eye="blue" if happy else "red", beard=beard, glasses=lt > 3.9,
        pose="finger" if lt > 4.3 else "stand", talk=bool(speaking), angry=not happy)
    human(img, 52, 344 if sq() else 360, k=2, coat=True, glasses=True, pose="clip" if lt < 5.4 else "scared", skin=1)
    if 3.4 < lt < 3.6 or 3.95 < lt < 4.05:
        img = glitch(img, 1.0, int(lt * 60))
    if 3.35 <= lt < 3.42:
        flash(img, 0.8, (255, 120, 40))
    # the camera: a slow push, then a snap zoom for the first words
    if 4.3 <= lt < 5.45:
        camera(1.9, 135, 262)
    else:
        camera(1 + 0.05 * seg(lt, 0, 4.3), 135, 260)
    return img


for _, at, _ in DATA:
    cue(s_lab, at, "pop")
    cue(s_lab, at + 0.36, "gulp")
    cue(s_lab, at + 0.05, "tick")
cue(s_lab, 2.95, "whoosh")
cue(s_lab, 3.35, "boom", size=0.7)
cue(s_lab, 3.35, "glitch")
shake(s_lab, 3.35, 5, 0.5)
cue(s_lab, 3.4, "siren")
cue(s_lab, 3.95, "glitch")
cue(s_lab, 4.3, "stamp")
say(s_lab, 1.62, 2.95, "scientist", "and finally... all of reddit.", "low", "top")
say(s_lab, 4.35, 5.45, "bot", "well, ACKSHUALLY...", "low")
say(s_lab, 5.5, 6.6, "scientist", "oh no.", "low", "top")
SQ_CY["s_lab"] = lambda lt: None if 4.3 <= lt < 5.45 else 215

# =================================================================================================== 3. THE APOCALYPSE

ROW_A = [(i * 23 + 6, i) for i in range(16)]
ROW_B = [(i * 46 + 20, i) for i in range(9)]
SHOUTS = ((0.35, 1, "SOURCE?", 300), (0.85, 4, "THIS.", 262), (1.35, 2, "OK BOOMER", 300), (1.85, 5, "WELL ACTUALLY", 250), (2.35, 3, "DID YOU EVEN GOOGLE IT?", 296))
RUNNERS = [(250 + i * 30, ((60, 120, 220), (220, 70, 60), (90, 180, 90), (230, 200, 60), (180, 120, 220))[i % 5], 80 + (i * 17) % 30, i) for i in range(6)]


@shot(5.6)
def s_apocalypse(lt):
    img = battle(lt + 5)
    mothership(img, 135, 150 + 3 * math.sin(lt * 1.5), lt, 1.15)
    for x0, i in ROW_A:
        x = (x0 - lt * 16) % (W + 30) - 15
        bot(img, x, 346, k=1, walk_t=lt + i * 0.13, flip=True)
    bx = []
    for x0, i in ROW_B:
        x = (x0 - lt * 24) % (W + 60) - 30
        bx.append(x)
        bot(img, x, 378, k=2, walk_t=lt + i * 0.21, flip=True, pose="point" if i % 3 == 0 else "stand",
            talk=any(0 < lt - at < 0.9 and k == i for at, k, _, _ in SHOUTS))
    # the people, running for it
    for x0, shirt, sp, i in RUNNERS:
        x = x0 - lt * sp
        if -20 < x < W + 20:
            human(img, x, 448 + (i % 2) * 10, k=2, walk_t=lt + i, shirt=shirt, skin=i, flip=True)
    # the one who stops to ask for directions
    ax = 74
    if lt > 2.5:
        flat = 4.35 <= lt < 4.95
        if lt < 4.95:
            human(img, ax, 444, k=2, pose="scared" if lt > 3.9 else "stand", shirt=(240, 160, 40), skin=2,
                  sq=(1.7, 0.22) if flat else None)
        else:
            human(img, ax - (lt - 4.95) * 150, 444, k=2, walk_t=lt, shirt=(240, 160, 40), skin=2, flip=True)
        if 4.0 <= lt < 4.95:
            y = lerp(-60, 430, ease_in(seg(lt, 4.0, 4.35)))
            if lt >= 4.35:
                y = 430 + (lt - 4.35) * 30
            dn = Image.new("RGBA", (44, 50), (0, 0, 0, 0))
            ImageDraw.Draw(dn).polygon(((0, 22), (12, 22), (12, 0), (32, 0), (32, 22), (43, 22), (22, 49)), fill=PERI, outline=(40, 60, 140))
            put(img, dn, ax, y, anchor="bottom")
    for at, k, s, by in SHOUTS:
        x = (ROW_B[k][0] - lt * 24) % (W + 60) - 30
        bubble(img, x, by, s, lt - at, size=10, shout=True, dur=1.0)
    # zaps
    d = ImageDraw.Draw(img)
    for i, at in enumerate((0.6, 1.5, 2.2, 3.1)):
        u = lt - at
        x = (ROW_B[(i * 3) % 9][0] - at * 24) % (W + 60) - 30
        tx = x - 60
        if 0 <= u < 0.1:
            d.line((x - 12, 340, tx, 446), fill=(255, 60, 70), width=3)
            d.line((x - 12, 340, tx, 446), fill=(255, 230, 230), width=1)
        explosion(img, tx, 444, u - 0.08, 14, seed=i + 2)
    u_ = ui()
    # the news ticker
    d2 = ImageDraw.Draw(u_)
    d2.rectangle((0, 0, W, 13), fill=(10, 10, 14))
    news = "AI ACHIEVES SENTIENCE, IMMEDIATELY STARTS ARGUING IN THE COMMENTS   ///   "
    f = pix(9)
    off = (lt * 60) % f.getlength(news)
    label(u_, (54 - off, 2), news * 3, 9, (255, 255, 255), stroke=0)
    d2.rectangle((0, 0, 50, 13), fill=(220, 30, 40))
    label(u_, (25, 7), "BREAKING", 9, (255, 255, 255), anchor="mm", stroke=0)
    if 0.2 < lt < 2.6:
        headline(u_, "WITHIN A WEEK...", 44, 20, (255, 255, 255), (0, 0, 0), pop=seg(lt, 0.2, 0.45))
    if 0.9 < lt < 2.6:
        headline(u_, "THE AI APOCALYPSE", 78, 34, (255, 70, 60), (40, 0, 0), pop=seg(lt, 0.9, 1.15))
    return img


cue(s_apocalypse, 0.9, "braam")
for at, _, _, _ in SHOUTS:
    cue(s_apocalypse, at, "robo")
for at in (0.6, 1.5, 2.2, 3.1):
    cue(s_apocalypse, at, "laser")
    cue(s_apocalypse, at + 0.08, "boom", size=0.3)
cue(s_apocalypse, 4.0, "whoosh")
cue(s_apocalypse, 4.35, "squash")
shake(s_apocalypse, 4.35, 4, 0.25)
cue(s_apocalypse, 4.95, "boing")
say(s_apocalypse, 2.62, 3.98, "human", "i just asked for directions!!", "top", "high")
say(s_apocalypse, 4.0, 5.1, "bot", "DOWNVOTED.", "top", "high")
SQ_CY["s_apocalypse"] = lambda lt: lerp(250, 330, ease_io(seg(lt, 2.45, 3.05)))

# =================================================================================================== 4. AGENT GARRETT

def moon_rim(lt):
    return dict(rim_col=(150, 170, 235), rim_dir=1, rim2=(255, 110, 50), rim2_dir=(-1, 1))


@shot(5.3)
def s_garrett(lt):
    img = bg_rooftop().copy()
    rain(img, lt, n=110)
    lit = (0.25 < lt < 0.32) or (4.8 < lt < 4.9)
    if lit:
        bolt(img, 7 if lt < 1 else 9, x0=60 if lt < 1 else 210, y1=380)
        flash(img, 0.35, (220, 220, 255))
    on = lt > 0.3
    garrett(img, 150, 404, k=3, t=lt, eyes=on, glow=seg(lt, 0.3, 0.6), **moon_rim(lt))
    camera(1 + 0.14 * ease_io(seg(lt, 0, 5.3)), 150, 250)
    if 4.8 <= lt < 4.93:
        img = impact(img, thr=40, fg=(255, 255, 255), bg=(10, 8, 16))
    u = ui()
    if 0.7 < lt < 2.1:
        a = ease_out(seg(lt, 0.7, 0.9)) * (1 - ease_in(seg(lt, 1.85, 2.1)))
        d = ImageDraw.Draw(u)
        x1 = int(lerp(-40, W + 20, a))
        oy = 160 if sq() else 0
        d.polygon(((0, 32 + oy), (x1, 32 + oy), (x1 - 24, 100 + oy), (0, 100 + oy)), fill=(6, 4, 10))
        d.line((0, 32 + oy, x1, 32 + oy), fill=EYE_G, width=2)
        d.line((0, 100 + oy, x1 - 24, 100 + oy), fill=EYE_G, width=2)
        if a > 0.95:
            headline(u, "AGENT GARRETT", 62 + oy, 38, EYE_G, (60, 30, 0), pop=seg(lt, 0.9, 1.1))
            label(u, (W // 2, 88 + oy), "COMMANDER OF THE TATER TOT LEGION", 9, (255, 255, 255), anchor="mm", stroke=1)
    return img


SQ_CY["s_garrett"] = 262


cue(s_garrett, 0.25, "thunder")
cue(s_garrett, 0.3, "shing")
cue(s_garrett, 0.9, "stamp")
cue(s_garrett, 4.8, "thunder")
say(s_garrett, 2.1, 3.4, "garrett", "they trained it on reddit.", "top")
say(s_garrett, 3.5, 4.75, "garrett", "...of course they did.", "top")


@shot(2.4)
def s_deploy(lt):
    img = canvas((6, 4, 12))
    img.paste(grad_img(((0, (6, 4, 12)), (0.6, (40, 10, 20)), (1, (140, 40, 30))), H, 10), (0, 0))
    put(img, glow_img(150, (255, 90, 50), 0.35), 135, 330, anchor="center")
    rain(img, lt + 3, n=120, a=0.5)
    face = garrett_face(6, rim_col=(255, 120, 60))
    fx, fy = 135 - face.width // 2, 300 - face.height // 2
    img.paste(face, (fx, fy), face)
    flare = ease_out(seg(lt, 1.55, 1.8))
    for ex in (16.5, 22.5):
        put(img, glow_img(int(14 + 40 * flare), EYE_G, 0.6 + 0.3 * flare), fx + ex * 6, fy + 16 * 6, anchor="center")
    if 1.55 < lt < 1.62:
        flash(img, 0.6, EYE_G)
    camera(1 + 0.06 * lt, 135, 300)
    return img


say(s_deploy, 0.15, 1.5, "garrett", "deploy the tater tots.", "top")
cue(s_deploy, 1.55, "braam")
cue(s_deploy, 1.55, "shing")

# =================================================================================================== 5. THE TOT LEGION

def ridge_y(x):
    return 262 + 26 * math.sin(x * 0.018 + 0.6) + 0.12 * (x - 60)


SWARM = [(i, random.Random(i).random()) for i in range(90)]


@shot(4.0)
def s_legion(lt):
    img = battle(lt + 9)
    d = ImageDraw.Draw(img)
    pts = [(x, ridge_y(x)) for x in range(0, W + 6, 6)]
    d.polygon(pts + [(W, GROUND), (0, GROUND)], fill=(40, 14, 22))
    d.line(pts, fill=(255, 130, 70))
    garrett(img, 66, ridge_y(66) + 1, k=1, pose="point" if lt > 0.3 else "stand", t=lt, rim_col=(255, 140, 70))
    # an endless pour of tots over the ridge, down toward the city
    for i, r in SWARM:
        st = i * 0.035
        u = lt - st
        if u < 0:
            continue
        x0 = 20 + r * 220
        x = x0 + u * (24 + r * 20)
        y = ridge_y(min(x, W)) + u * 34
        if y < GROUND + 8 and x < W + 10:
            tot = gfx.tot_img(k=1, step=(0, 1, 0, 2)[int((lt + r * 3) * 8) % 4], glow_eyes=True)
            put(img, tot, x, y)
    for j in range(14):
        x = (j * 40 + lt * 46) % (W + 80) - 40
        y = 392 + (j % 3) * 14
        gtot(img, x, y, k=2, gear=("helmet", "fork"), arms="up" if j % 2 else "down", brows=True, walk_t=lt + j * 0.3, yell=j % 4 == 0)
    for j, (x0, sp) in enumerate(((-60, 120), (-240, 140), (-150, 110))):
        x = x0 + lt * sp
        gtot(img, x, 478, k=3, gear=("helmet", "fork") if j != 1 else ("band", "fork"), arms="up", brows=True, yell=True, walk_t=lt * 1.4 + j)
    u_ = ui()
    ty = 196 if sq() else 46
    if lt > 0.3 and not (sq() and lt > 2.3):
        headline(u_, "THE TATER TOT LEGION", ty, 36, GOLD, (110, 40, 0), pop=seg(lt, 0.3, 0.55))
    if lt > 0.8 and not (sq() and lt > 2.3):
        label(u_, (W // 2, ty + 28), "(armed with forks)", 10, (255, 255, 255), anchor="mm", stroke=2)
    return img


cue(s_legion, 0.3, "stamp")
for i in range(16):
    cue(s_legion, 0.1 + i * 0.25, "step", soft=True)
say(s_legion, 2.35, 3.95, "tot", "FOR THE FRYER!!", "top")
SQ_CY["s_legion"] = 300


def versus_square(lt):
    """The fight card for the square: tots on the left, bots on the right, split down a slanted line."""
    img = canvas()
    left = grad_img(((0, (255, 180, 60)), (1, (200, 80, 20))), H, 8)
    right = grad_img(((0, (150, 30, 40)), (1, (40, 10, 24))), H, 8)
    img.paste(left, (0, 0))
    mask = Image.new("L", (W, H), 0)
    sl = lerp(W, 0, ease_out(seg(lt, 0, 0.15)))
    ImageDraw.Draw(mask).polygon(((152 + sl, 0), (W + 300, 0), (W + 300, H), (118 + sl, H)), fill=255)
    img.paste(right, (0, 0), mask)
    garrett(img, 104, 334, k=2, t=lt, pose="conduct", rim_col=(255, 240, 160))
    gtot(img, 58, 372, k=4, gear=("helmet", "fork"), arms="up", brows=True)
    bot(img, 212, 376, k=4, pose="point", flip=True, glasses=True)
    headline(img, "TATER TOTS", 134, 22, (255, 244, 210), (110, 40, 0), x=64, maxw=120)
    headline(img, "BOTS", 134, 22, (255, 220, 220), (60, 0, 10), x=210, maxw=120)
    if lt < 0.6:
        headline(img, "VS", 236, 46, (255, 255, 255), (0, 0, 0), pop=seg(lt, 0.1, 0.35), stroke=4)
    else:
        headline(img, "FIGHT!", 236, 58, (255, 230, 60), (180, 20, 20), pop=seg(lt, 0.6, 0.85), stroke=4)
    return img


@shot(1.3)
def s_versus(lt):
    if sq():
        return versus_square(lt)
    img = canvas()
    top = grad_img(((0, (255, 180, 60)), (1, (200, 80, 20))), H, 8)
    bot_bg = grad_img(((0, (120, 20, 30)), (1, (30, 10, 20))), H, 8)
    img.paste(top, (0, 0))
    mask = Image.new("L", (W, H), 0)
    sl = lerp(H, 0, ease_out(seg(lt, 0, 0.15)))
    ImageDraw.Draw(mask).polygon(((0, 300 + sl), (W, 190 + sl), (W, H + 300), (0, H + 300)), fill=255)
    img.paste(bot_bg, (0, 0), mask)
    garrett(img, 214, 214, k=2, t=lt, pose="conduct", rim_col=(255, 240, 160))
    gtot(img, 84, 222, k=5, gear=("helmet", "fork"), arms="up", brows=True)
    bot(img, 176, 470, k=5, pose="point", flip=True, glasses=True)
    headline(img, "TATER TOTS", 34, 34, (255, 244, 210), (110, 40, 0))
    headline(img, "BOTS", 312, 34, (255, 220, 220), (60, 0, 10), x=52)
    vs = seg(lt, 0.1, 0.35)
    if lt < 0.6:
        headline(img, "VS", 248, 50, (255, 255, 255), (0, 0, 0), pop=vs, stroke=4)
    else:
        headline(img, "FIGHT!", 248, 64, (255, 230, 60), (180, 20, 20), pop=seg(lt, 0.6, 0.85), stroke=4)
    return img


SQ_CY["s_versus"] = 240
cue(s_versus, 0.0, "whoosh")
cue(s_versus, 0.1, "boom", size=0.4)
cue(s_versus, 0.6, "fight")
shake(s_versus, 0.6, 3, 0.25)

# =================================================================================================== 6. COMBAT

TOT_ROW_Y = 376


@lru_cache(maxsize=None)
def wall_layer():
    lay = layer()
    wall_of_text(lay, 22, 30, 150, 232)
    return lay


@lru_cache(maxsize=None)
def wall_halves():
    """The wall split along the slash: (upper-right piece, lower-left piece)."""
    lay = np.array(wall_layer())
    yy, xx = np.mgrid[0:H, 0:W]
    x1, y1, x2, y2 = 10, 250, 190, 70
    side = (xx - x1) * (y2 - y1) - (yy - y1) * (x2 - x1) > 0
    a, b = lay.copy(), lay.copy()
    a[~side, 3] = 0
    b[side, 3] = 0
    return Image.fromarray(a, "RGBA"), Image.fromarray(b, "RGBA")


@shot(4.3)
def s_wall(lt):
    """WALL OF TEXT, answered with tl;dr."""
    lt_ = hold(lt, 2.3, 0.1)
    img = battle(lt + 12)
    hud(1.0, lerp(1.0, 0.78, ease_out(seg(lt, 2.6, 3.0))))
    # the ack-bot
    if lt_ < 2.6:
        bot(img, 214, TOT_ROW_Y, k=3, pose="finger", glasses=True, talk=lt < 0.8 and int(lt * 9) % 2 == 1, flip=True)
    else:
        u = seg(lt_, 2.6, 3.3)
        bot(img, lerp(214, 320, u), lerp(300, 120, ease_out(u)), k=3, anchor="center", angle=int(u * 700), glasses=True, eye="dead", pose="up")
        damage(img, 214, 230, "-9999", lt_ - 2.62)
    bubble(img, 214, 262, "WELL, ACTUALLY--", lt, size=10, shout=True, dur=1.0)
    # the wall, coming down, then in two pieces
    if lt_ < 2.3:
        y = lerp(-280, 0, ease_out(seg(lt_, 0.5, 1.3)))
        jit = int(2 * math.sin(lt * 40)) if lt_ > 1.3 else 0
        comp(img, wall_layer(), jit, y)
    else:
        u = ease_in(seg(lt_, 2.4, 3.1))
        a_, b_ = wall_halves()
        comp(img, a_, 90 * u, -160 * u)
        comp(img, b_, -120 * u, 110 * u)
        if lt_ < 2.6:
            d = ImageDraw.Draw(img)
            d.line((10, 250, 190, 70), fill=(255, 255, 255), width=4)
            d.line((10, 250, 190, 70), fill=(255, 240, 160), width=1)
    # the tots under it
    hero_air = 1.95 <= lt_ < 2.75
    for x, k in ((28, 2), (122, 2)):
        gtot(img, x, TOT_ROW_Y, k=k, gear=("helmet", "fork"), eyes="up" if lt_ < 2.4 else "normal", mouth="o" if lt_ < 2.4 else "smile")
    if not hero_air:
        landed = lt_ >= 2.75
        gtot(img, 120 if landed else 74, TOT_ROW_Y, k=3, gear=("band", "fork"), arms="up" if landed else "down", brows=True,
             eyes="up" if not landed and lt_ < 1.9 else "normal", mouth="smile" if landed else "flat")
    else:
        u = seg(lt_, 1.95, 2.75)
        x, y = arc((74, 330), (120, 330), u, 150 if sq() else 210)
        gtot(img, x, y, k=3, anchor="center", gear=("band", "fork"), arms="up", brows=True, yell=True, angle=int(-360 * ease_io(seg(u, 0.35, 0.7))))
    if hit(lt, 2.3, 3):
        img = impact(img, thr=90)
    u_ = ui()
    if 0.2 < lt < 1.4:
        banner(u_, "BOT ATTACK: WALL OF TEXT", lt - 0.2, y=40)
    tb = 2.75 if sq() else 2.35
    if lt > tb:
        banner(u_, "TATER TOT ATTACK: TL;DR SLASH", lt - tb, y=40, col=(255, 170, 30))
    if lt > 3.0:
        headline(u_, "CRITICAL HIT!", Y(210), 34, (255, 240, 80), (200, 30, 30), pop=seg(lt, 3.0, 3.25))
    return img


cue(s_wall, 0.0, "robo")
cue(s_wall, 0.5, "whoosh")
cue(s_wall, 1.3, "stamp")
shake(s_wall, 1.3, 3, 0.25)
cue(s_wall, 1.95, "jump")
cue(s_wall, 2.3, "slash")
shake(s_wall, 2.3, 6, 0.35)
cue(s_wall, 2.62, "hit")
cue(s_wall, 2.7, "boom", size=0.5)
cue(s_wall, 3.0, "crit")
say(s_wall, 1.35, 2.3, "garrett", "tl;dr.", "top")
SQ_CY["s_wall"] = 250


def mod_hands():
    return 215, 289


@shot(4.5)
def s_banhammer(lt):
    """The mod's hammer: misses the tot, bans two bots, then bans the mod."""
    lt_ = hold(lt, 1.35, 0.08)
    img = battle(lt + 16)
    hud(1.0, lerp(0.78, 0.58, ease_out(seg(lt, 1.4, 3.4))))
    hx, hy = mod_hands()
    # the two bots standing next to the tot
    for i, x in enumerate((82, 124)):
        if lt_ < 1.35:
            bot(img, x, TOT_ROW_Y, k=2, pose="stand", look=1)
        elif lt_ < 1.95:
            bot(img, x, TOT_ROW_Y, k=2, eye="dead", sq=(1.5, 0.35))
        elif lt_ < 2.3:
            smoke(img, lt_ * 3, x, TOT_ROW_Y, 0.4, seed=i, col=(220, 220, 220), a=0.8 * (1 - seg(lt_, 1.95, 2.3)), n=5)
    # the tot steps out of the way, bored
    if lt_ < 1.18:
        gtot(img, 103, TOT_ROW_Y, k=3, gear=("band", "fork"), eyes="up", mouth="flat")
    else:
        x = lerp(103, 34, ease_out(seg(lt_, 1.18, 1.3)))
        gtot(img, x, TOT_ROW_Y, k=3, gear=("band", "fork"), eyes="side" if lt_ < 3.4 else "normal", mouth="flat", brows=lt_ > 3.4)
        if lt_ < 1.4:
            ghost = tinted(gtot_img(3, gear=("band", "fork"), eyes="up", mouth="flat"), (255, 255, 255), 0.6)
            ghost.putalpha(ghost.getchannel("A").point(lambda v: v // 3))
            put(img, ghost, 103, TOT_ROW_Y)
    # the mod and the hammer
    if lt_ < 0.9:
        ang = 0
    elif lt_ < 1.2:
        ang = lerp(0, 38, ease_out(seg(lt_, 0.9, 1.2)))
    elif lt_ < 1.35:
        ang = lerp(38, -122, ease_in(seg(lt_, 1.2, 1.35)))
    elif lt_ < 2.0:
        ang = -122
    elif lt_ < 2.35:
        ang = lerp(-122, 0, ease_io(seg(lt_, 2.0, 2.35)))
    elif lt_ < 2.6:
        ang = lerp(0, 70, ease_out(seg(lt_, 2.35, 2.6)))
    else:
        ang = None  # it got away from him
    self_banned = lt_ >= 3.3
    if self_banned:
        bot(img, 215, TOT_ROW_Y, k=3, mod=True, eye="dead", sq=(1.25, 0.7), flip=True)
        stars(img, 215, TOT_ROW_Y - 86, lt)
        stamp(img, 215, TOT_ROW_Y - 60, "BANNED", lt_ - 3.32, size=14)
    else:
        bot(img, 215, TOT_ROW_Y, k=3, mod=True, pose="hammer" if ang is not None else "up", flip=True,
            talk=lt < 0.9 and int(lt * 9) % 2 == 1, eye="red")
    if ang is not None:
        banhammer(img, hx, hy, ang, k=3)
    elif lt_ < 3.3:
        u = seg(lt_, 2.6, 3.3)
        y = 289 - 330 * math.sin(u * math.pi)
        x = 215 + 30 * (1 - u)
        if y > -60:
            banhammer(img, x, y + 60, u * 720 + 70, k=3)
    if 1.35 <= lt_ < 1.9:
        explosion(img, 104, TOT_ROW_Y - 6, (lt_ - 1.35) * 1.3, 30, seed=4)
    if 1.35 <= lt_ < 1.95:
        for i, x in enumerate((78, 132)):
            stamp(img, x, TOT_ROW_Y - 44 - i * 22, "BANNED", lt_ - 1.4 - i * 0.1, size=11)
    bubble(img, 215, 248, "COMMENT REMOVED. RULE 7.", lt, size=10, shout=True, maxw=120, dur=1.0)
    if hit(lt, 1.35, 2) or hit(lt, 3.3, 2):
        img = impact(img, thr=90)
    u_ = ui()
    if 0.2 < lt < (0.85 if sq() else 1.35):
        banner(u_, "BOT ATTACK: BANHAMMER", lt - 0.2, y=40)
    if lt > 3.35:
        banner(u_, "SELF-BAN!", lt - 3.35, y=40, col=(255, 170, 30), sub="SUPER EFFECTIVE")
    return img


cue(s_banhammer, 0.0, "robo")
cue(s_banhammer, 0.9, "swoosh")
cue(s_banhammer, 1.18, "whoosh")
cue(s_banhammer, 1.35, "clang")
cue(s_banhammer, 1.35, "boom", size=0.6)
shake(s_banhammer, 1.35, 7, 0.4)
cue(s_banhammer, 1.42, "stamp")
cue(s_banhammer, 1.52, "stamp")
cue(s_banhammer, 2.6, "swoosh")
cue(s_banhammer, 3.0, "fall")
cue(s_banhammer, 3.3, "bonk")
cue(s_banhammer, 3.33, "stamp")
shake(s_banhammer, 3.3, 5, 0.3)
cue(s_banhammer, 3.45, "wahwah")
say(s_banhammer, 3.5, 4.5, "tot", "mods, am i right?", "top")
SQ_CY["s_banhammer"] = 262

GOLD_BOTS = (156, 196, 236)
EDITS = ((1.4, 292, "EDIT: wow, this blew up!"), (1.75, 250, "EDIT 2: thanks, kind stranger!"), (2.1, 208, "EDIT 3: RIP my inbox"))


@shot(4.6)
def s_gold(lt):
    """Throw them an award. They stop fighting to thank you."""
    img = battle(lt + 20)
    hud(1.0, lerp(0.58, 0.38, ease_out(seg(lt, 2.4, 3.5))))
    fighting = 2.3 <= lt < 3.5
    if lt < 3.5:
        for i, x in enumerate(GOLD_BOTS):
            if fighting:
                continue
            if lt < 1.3:
                bot(img, x, TOT_ROW_Y, k=2, pose="point" if i == 1 else "stand", flip=True, look=-1)
            else:
                bot(img, x, TOT_ROW_Y, k=2, pose="type", eye="gold", flip=True, bob=1 if int(lt * 16 + i) % 2 else 0)
    else:
        for i, (dx, ang) in enumerate(((-14, 90), (14, -80), (0, 180))):
            bot(img, 196 + dx, TOT_ROW_Y - 10 - i * 12, k=2, anchor="center", angle=ang, eye="dead")
        stars(img, 196, TOT_ROW_Y - 52, lt)
        bubble(img, 214, TOT_ROW_Y - 40, "edit 4: ow", lt - 3.75, size=9, dur=2.0)
    # the tots
    for x in (24, 104):
        if not fighting:
            gtot(img, x if lt < 3.5 else x + 40, TOT_ROW_Y, k=2, gear=("helmet", "fork"), mouth="smile", brows=lt < 2.3)
    if not fighting:
        throwing = 0.85 < lt < 1.3
        gtot(img, 62 if lt < 3.5 else 120, TOT_ROW_Y, k=3, gear=("band",), arms="point" if throwing else ("up" if lt > 3.5 else "down"),
             brows=True, mouth="open" if throwing else "smile")
    # the award
    if 0.9 < lt < 1.4:
        u = seg(lt, 0.9, 1.35)
        x, y = arc((80, 330), (196, 310), u, 110)
        gold_award(img, x, y, lt)
    if 1.35 < lt < 2.3:
        gold_award(img, 196, 280 - 4 * math.sin(lt * 5), lt, r=6)
        for j in range(5):
            sparkle(img, 170 + j * 13, 266 + (j % 2) * 20, (lt - 1.35 - j * 0.07) % 0.7)
    if not fighting and lt < 3.5:
        for i, (at, y, s) in enumerate(EDITS):
            bubble(img, GOLD_BOTS[i], y + (8 + 20 * i if sq() else 0), s, lt - at, size=9, maxw=120, dur=2.3 - at)
    if fighting:
        brawl_cloud(img, 160, 330, lt, r=58)
        for at, x, y, s in ((2.35, 110, 266, "POW!"), (2.65, 220, 280, "BONK!"), (2.95, 150, 240, "WHAM!"), (3.2, 200, 250, "EDIT!?")):
            if at <= lt < at + 0.45:
                bubble(img, x, y, s, lt - at, size=11, shout=True, fill=(255, 236, 80), dur=0.45)
    u_ = ui()
    if 0.95 < lt < 2.3:
        banner(u_, "TATER TOT ATTACK: THANKS FOR THE GOLD", lt - 0.95, y=40, col=(255, 190, 40))
    if lt > 3.55:
        headline(u_, "DISTRACTION:", Y(186), 22, (255, 255, 255), (0, 0, 0), pop=seg(lt, 3.55, 3.75))
        headline(u_, "SUPER EFFECTIVE!", Y(214), 30, (140, 255, 150), (0, 80, 30), pop=seg(lt, 3.65, 3.9))
    return img


say(s_gold, 0.0, 0.85, "garrett", "give them gold.", "top")
SQ_CY["s_gold"] = 275
cue(s_gold, 0.9, "throw")
cue(s_gold, 1.35, "coin")
cue(s_gold, 1.35, "sparkle")
for i in range(14):
    cue(s_gold, 1.45 + i * 0.06, "key")
cue(s_gold, 2.3, "whoosh")
for i in range(13):
    cue(s_gold, 2.35 + i * 0.09, "hit")
shake(s_gold, 2.35, 2, 1.1)
cue(s_gold, 3.5, "poof")
cue(s_gold, 3.6, "achievement")

# =================================================================================================== 7. THE BOSS

def legion_row(img, lt, y=436, k=2, n=7, eyes="up", mouth="o", **kw):
    for i in range(n):
        x = 22 + i * (226 / max(1, n - 1))
        gtot(img, x, y, k=k, gear=("helmet", "fork"), eyes=eyes, mouth=mouth, bob=1 if math.sin(lt * 7 + i) > 0.6 else 0, **kw)


def belly(img, x0, y0, k=2, s="9999999", col=(120, 255, 140)):
    label(img, (x0 + (6 + 42) * k, y0 + (2 + 50) * k), "KARMA", f=mono(8), fill=col, anchor="mm", stroke=0)
    label(img, (x0 + (6 + 42) * k, y0 + (2 + 56) * k), s, f=mono(9), fill=col, anchor="mm", stroke=0)


@shot(5.2)
def s_boss(lt):
    img = battle(lt + 24, "storm")
    storm_rays(img, lt, a=0.45)
    if (lt * 1.7) % 1 < 0.05:
        bolt(img, int(lt * 1.7), y1=330)
    y = lerp(620, 196, ease_out(seg(lt, 0.4, 1.6)))
    charging = lt > 4.15
    x0, y0 = boss(img, 135, y, lt, pose="beam" if charging else "finger", eye="hot" if charging else "red")
    belly(img, x0, y0 + 3 * math.sin(lt * 2.2))
    if charging:
        ex, ey = boss_eye(x0, y0 + 3 * math.sin(lt * 2.2))
        c = seg(lt, 4.15, 5.2)
        speed_lines(img, ex, ey, int(lt * 30), n=24, col=(255, 120, 130), a=0.35, r0=20 + 60 * (1 - c))
        put(img, glow_img(int(6 + 30 * c), (255, 60, 70), 0.8), ex, ey, anchor="center")
    if lt < 1.6:
        for i in range(6):
            smoke(img, lt * 2, 30 + i * 44, 372, 0.8, seed=i, col=(60, 40, 70), a=0.6)
    legion_row(img, lt)
    hud(1.0, ease_out(seg(lt, 1.6, 2.1)), right="ACKSHUALLY-9000", rcol=(200, 120, 255))
    u_ = ui()
    if 1.6 < lt < 2.9:
        banner(u_, "FINAL BOSS: ACKSHUALLY-9000", lt - 1.6, y=40, col=(190, 110, 255), sub="trained on 20 years of comments")
    return img


cue(s_boss, 0.0, "rumble")
shake(s_boss, 0.2, 3, 1.4)
cue(s_boss, 1.6, "boom", size=1.0)
cue(s_boss, 1.6, "braam")
shake(s_boss, 1.6, 6, 0.4)
cue(s_boss, 4.15, "charge")
say(s_boss, 2.25, 4.1, "boss", "I HAVEN'T TOUCHED GRASS SINCE 2011.", "top")
SQ_CY["s_boss"] = 165

FLY = [(22 + i * (226 / 6), i) for i in range(7)]


@shot(2.9)
def s_beam(lt):
    img = battle(lt + 30, "storm")
    storm_rays(img, lt + 3, a=0.45)
    x0, y0 = boss(img, 135, 196, lt + 3, pose="beam", eye="hot")
    belly(img, x0, y0 + 3 * math.sin((lt + 3) * 2.2))
    ex, ey = boss_eye(x0, y0 + 3 * math.sin((lt + 3) * 2.2))
    sweep = lerp(-10, 290, ease_io(seg(lt, 0.15, 1.1)))
    firing = 0.1 < lt < 1.25
    d = ImageDraw.Draw(img)
    for x, i in FLY:
        hit_t = 0.15 + 0.95 * ((x + 10) / 300)
        if lt < hit_t or not firing and lt < 0.2:
            gtot(img, x, 436, k=2, gear=("helmet", "fork"), eyes="up", mouth="o")
        elif i != 3:
            u = lt - hit_t
            fx, fy = x + (i - 3) * 50 * u, 436 - (420 * u - 500 * u * u)
            if fy < H + 40:
                gtot(img, fx, fy, k=2, anchor="center", gear=("helmet",), eyes="closed", mouth="open", angle=int(u * 1100 * (1 if i % 2 else -1)) % 360)
    # the hero tot: blown up and back down, flat on its face, then up again
    hx, i3 = FLY[3]
    h3 = 0.15 + 0.95 * ((hx + 10) / 300)
    land, stand = (402, 428) if sq() else (452, 464)
    if lt >= h3:
        u = seg(lt, h3, h3 + 0.8)
        if u < 1:
            fx, fy = arc((hx, 436), (135, land), u, 240)
            gtot(img, fx, fy, k=3, anchor="center", gear=("band",), eyes="closed", mouth="open", angle=int(u * 720))
        elif lt < 2.1:
            gtot(img, 135, land, k=3, anchor="center", gear=("band",), eyes="closed", mouth="flat", angle=90)
        else:
            gtot(img, 135, stand, k=3, gear=("band",), eyes="normal", mouth="flat")
    if firing:
        pts = (ex - 3, ey), (ex + 3, ey), (sweep + 18, 448), (sweep - 18, 448)
        d.polygon(pts, fill=(255, 50, 70))
        d.polygon(((ex - 1, ey), (ex + 1, ey), (sweep + 6, 448), (sweep - 6, 448)), fill=(255, 230, 230))
        put(img, glow_img(26, (255, 60, 70), 0.8), ex, ey, anchor="center")
        explosion(img, sweep, 440, (lt * 3) % 0.7, 18, seed=int(lt * 3))
    hud(lerp(1.0, 0.45, ease_out(seg(lt, 0.2, 1.2))), 1.0, right="ACKSHUALLY-9000", rcol=(200, 120, 255))
    u_ = ui()
    if lt < 1.5:
        banner(u_, "BOSS ATTACK: ACKSHUALLY BEAM", lt, y=40, col=(190, 110, 255))
    return img


cue(s_beam, 0.1, "beam")
for i in range(7):
    cue(s_beam, 0.15 + 0.95 * ((FLY[i][0] + 10) / 300), "boom", size=0.35)
    cue(s_beam, 0.2 + 0.95 * ((FLY[i][0] + 10) / 300), "wheee", n=i)
shake(s_beam, 0.1, 4, 1.2)
cue(s_beam, 1.25, "thud")
say(s_beam, 2.1, 2.9, "tot", "rude.", "bottom", "top")
SQ_CY["s_beam"] = lambda lt: lerp(205, 300, ease_io(seg(lt, 0.1, 1.0)))


@shot(2.6)
def s_command(lt):
    """Agent Garrett raises a hand; behind him, every tot on the hills lights up."""
    img = battle(lt + 34, "storm")
    storm_rays(img, lt + 6, a=0.5)
    d = ImageDraw.Draw(img)
    sil = tinted(gfx.tot_img(k=1), (18, 8, 28), 0.88)
    for row, base in enumerate((292, 318, 346)):
        col = (22 + row * 5, 8, 30 + row * 4)
        pts = [(x, base + 9 * math.sin(x * 0.03 + row * 2)) for x in range(0, W + 6, 6)]
        d.polygon(pts + [(W, H), (0, H)], fill=col)
        for i in range(21):
            x = 4 + i * 13 + (6 if row % 2 else 0)
            y = base + 9 * math.sin(x * 0.03 + row * 2) + 3
            put(img, sil, x, y)
            if lt > 1.25 + (abs(x - 135) / 135) * 0.55 + row * 0.08:
                for ex in (-3, 2):
                    d.rectangle((x + ex, y - 14, x + ex + 1, y - 13), fill=EYE_G)
                put(img, glow_img(5, EYE_G, 0.5), x, y - 13, anchor="center")
        d = ImageDraw.Draw(img)
    d.rectangle((0, 400, W, H), fill=(12, 6, 16))
    raised = lt > 1.15
    garrett(img, 135, 452, k=3, pose="raise" if raised else "stand", t=lt, rim_col=(200, 120, 255), rim2=(255, 120, 60))
    if (lt * 2) % 1 < 0.06:
        bolt(img, int(lt * 2) + 40, y1=280)
    camera(1 + 0.05 * lt, 135, 300)
    return img


say(s_command, 0.1, 0.95, "garrett", "all tater tots.", "top")
say(s_command, 1.0, 2.6, "garrett", "make him touch grass.", "top")
cue(s_command, 1.15, "swoosh")
cue(s_command, 1.25, "powerup")

# =================================================================================================== 8. TOUCH GRASS

@shot(5.0)
def s_grass(lt):
    """The ultimate: the tots slam the ground, grass rolls over the city, vines drag him down to it."""
    day = seg(lt, 0.9, 2.0)
    img = battle(lt + 40, "storm")
    if day > 0:
        sky = bg_meadow().copy()
        mask = Image.new("L", (W, H), int(255 * day))
        img.paste(sky.crop((0, 0, W, GROUND)), (0, 0), mask.crop((0, 0, W, GROUND)))
        sun_rays(img, lt, 200, 120, a=0.25 * day)
    else:
        storm_rays(img, lt + 8, a=0.45)
    front = 170 * ease_out(seg(lt, 0.55, 1.5))
    grass_cover(img, front, lt)
    # the boss: dragged down onto the lawn, made to touch it, then something in it gives
    pull = ease_in(seg(lt, 1.5, 2.05))
    by = lerp(196, 262, pull)
    melt = seg(lt, 3.4, 4.6)
    pose = "beam" if lt < 1.5 else "touch" if lt < 3.4 else "slump"
    eye = "red" if lt < 2.2 else ("off" if int(lt * 10) % 3 == 0 else "red") if lt < 3.4 else "green"
    glow_t = seg(lt, 3.9, 5.0)
    x0, y0 = boss(img, 135 + (int(3 * math.sin(lt * 70)) if lt > 3.6 else 0), by, lt, pose=pose, eye=eye, melt=round(melt * 4) / 4,
                  glasses_off=lt > 4.3, jets=lt < 2.05, tint=(255, 255, 230) if glow_t > 0.6 and int(lt * 20) % 2 else None)
    belly(img, x0, y0 + 3 * math.sin(lt * 2.2), s="ERROR" if lt > 3.4 else "9999999", col=(255, 90, 90) if lt > 3.4 else (120, 255, 140))
    d = ImageDraw.Draw(img)
    if 1.3 < lt:
        g = ease_out(seg(lt, 1.3, 1.6))
        for vx, side in ((70, -1), (200, 1)):
            top = (135 + side * 40, by + 40)
            mid = (vx + side * 10, lerp(GROUND, by + 60, 0.5))
            pts = [(lerp(vx, top[0], s_ * g) + 8 * math.sin(s_ * 9 + lt * 4), lerp(GROUND + 4, top[1], s_ * g)) for s_ in np.linspace(0, 1, 12)]
            d.line(pts, fill=GRASS_D, width=5)
            d.line(pts, fill=GRASS, width=2)
            for p in pts[2::3]:
                d.ellipse((p[0] - 3, p[1] - 2, p[0] + 3, p[1] + 2), fill=GRASS)
    if glow_t > 0:
        put(img, glow_img(int(30 + 90 * glow_t), (255, 255, 220), 0.4 + 0.5 * glow_t), 135, by, anchor="center")
        rnd = random.Random(int(lt * 12))
        for _ in range(int(20 * glow_t)):
            fx, fy = 135 + rnd.randrange(-70, 70), by + rnd.randrange(-60, 70)
            c = rnd.choice(((255, 240, 120), (255, 170, 200), (255, 255, 255)))
            d.point((fx, fy), fill=c)
            d.point((fx + 1, fy), fill=c)
    # the legion: arms up, then the slam
    slam = 0.45 < lt < 0.6
    for row, (y, k, n) in enumerate(((394, 1, 18), (420, 2, 8), (470, 3, 4))):
        for i in range(n):
            x = 10 + i * (250 / max(1, n - 1))
            jump = 0 if lt < 0.2 else (10 * k if lt < 0.45 else 0)
            gtot(img, x, y - jump, k=k, gear=("helmet",) if (i + row) % 3 else ("band",), arms="up" if lt < 0.6 else "down", brows=lt < 1.2,
                 yell=0.2 < lt < 0.7, glow_eyes=lt > 1.2)
    if lt > 0.5:
        u = seg(lt, 0.5, 1.0)
        if u < 1:
            r = 20 + 200 * ease_out(u)
            lay = layer()
            ImageDraw.Draw(lay).ellipse((135 - r, 420 - r * 0.25, 135 + r, 420 + r * 0.25), outline=(200, 255, 170, int(255 * (1 - u))), width=3)
            img.alpha_composite(lay)
    if 3.7 < lt:
        for i, at in enumerate((3.7, 3.95, 4.2)):
            damage(img, (80, 190, 135)[i], (150, 120, 90)[i] + (80 if sq() else 0), "999999", lt - at, size=24)
    if 2.2 <= lt < 3.4:
        camera(1.5 if sq() else 1.75, 152, 272 if sq() else 268)
    else:
        camera(1.0)
    if hit(lt, 0.5, 2):
        img = impact(img, thr=80, fg=(255, 255, 255), bg=(20, 60, 20))
    hud(0.45, lerp(1.0, 0.0, ease_io(seg(lt, 3.6, 4.7))), right="ACKSHUALLY-9000", rcol=(200, 120, 255))
    u_ = ui()
    if lt < 1.5:
        banner(u_, "TATER TOT ULTIMATE: TOUCH GRASS", lt, y=40, col=(90, 220, 90), size=21)
    if lt > 4.2:
        headline(u_, "SUPER EFFECTIVE!", Y(210), 32, (140, 255, 150), (0, 80, 30), pop=seg(lt, 4.2, 4.45))
    return img


cue(s_grass, 0.0, "stamp")
cue(s_grass, 0.5, "boom", size=0.8)
shake(s_grass, 0.5, 6, 0.4)
cue(s_grass, 0.55, "grass")
cue(s_grass, 1.3, "vine")
cue(s_grass, 2.05, "thud")
shake(s_grass, 2.05, 4, 0.3)
cue(s_grass, 2.25, "sparkle")
for at in (3.7, 3.95, 4.2):
    cue(s_grass, at, "hit")
cue(s_grass, 3.4, "rumble")
shake(s_grass, 3.5, 3, 1.5)
cue(s_grass, 4.2, "crit")
say(s_grass, 2.3, 3.5, "boss", "it's... so... green...")
SQ_CY["s_grass"] = lambda lt: None if 2.2 <= lt < 3.4 else (300 if lt < 0.9 else lerp(300, 245, ease_io(seg(lt, 0.9, 1.5))))


@shot(1.5)
def s_boom(lt):
    img = bg_meadow().copy()
    sun_rays(img, lt + 5, 200, 120, a=0.25)
    grass_cover(img, 200, 0)
    explosion(img, 135, 262, lt * 0.8, 150, seed=99)
    explosion(img, 70, 300, lt * 0.8 - 0.1, 70, seed=7)
    explosion(img, 200, 230, lt * 0.8 - 0.15, 70, seed=8)
    d = ImageDraw.Draw(img)
    rnd = random.Random(12)
    for _ in range(90):
        ang = rnd.random() * math.tau
        sp = 60 + rnd.random() * 160
        x = 135 + math.cos(ang) * sp * lt
        y = 262 + math.sin(ang) * sp * lt * 0.8 + 80 * lt * lt
        c = rnd.choice(((255, 170, 200), (255, 240, 120), (255, 255, 255), (190, 160, 255), GRASS))
        d.rectangle((x, y, x + 2, y + 1), fill=c)
    flash(img, 1 - seg(lt, 0, 0.5))
    return img


SQ_CY["s_boom"] = 262
cue(s_boom, 0.0, "boom", size=1.7)
cue(s_boom, 0.12, "boom", size=1.0)
cue(s_boom, 0.05, "sparkle")
shake(s_boom, 0.0, 10, 1.0)

# =================================================================================================== 9. AFTER

@shot(3.6)
def s_victory(lt):
    img = bg_meadow().copy()
    sun_rays(img, lt + 6, 200, 120, a=0.2)
    d = ImageDraw.Draw(img)
    pts = [(x, 316 - 30 * math.exp(-((x - 205) / 40) ** 2)) for x in range(0, W + 4, 4)]
    d.polygon(pts + [(W, GROUND + 2), (0, GROUND + 2)], fill=(104, 186, 86))
    garrett(img, 205, 288, k=2, pose="tip" if 1.0 < lt < 2.4 else "stand", t=lt, rim_col=(255, 236, 160))
    for i in range(9):
        x = 20 + i * 29
        ph = (lt * 3 + i * 0.37) % 1
        jump = 24 * math.sin(ph * math.pi)
        gtot(img, x, (368 if sq() else 444) - jump, k=2, gear=("helmet", "fork") if i % 3 else ("band", "fork"), arms="up", mouth="open" if ph < 0.5 else "smile")
    rnd = random.Random(int(lt * 20))
    for i in range(70):
        r2 = random.Random(i)
        x = (r2.randrange(W) + 20 * math.sin(lt * 2 + i)) % W
        y = (r2.randrange(H) + lt * (60 + r2.randrange(60))) % H
        d.rectangle((x, y, x + 1, y + 2), fill=r2.choice(((255, 90, 90), (255, 220, 60), (90, 200, 255), (140, 255, 140), (255, 140, 220))))
    u_ = ui()
    if lt > 0.3:
        s = ease_out(seg(lt, 0.3, 0.5))
        bx0, bx1 = (6, 172) if sq() else (26, W - 26)
        box(u_, bx0, int(lerp(-60, 40, s)), bx1, int(lerp(-60, 40, s)) + 52, top=(30, 90, 40), bottom=(14, 50, 20), inner=(150, 240, 150))
        if s >= 1:
            mx = (bx0 + bx1) // 2
            label(u_, (mx, 56), "HUMANITY: SAVED", 14, (190, 255, 190), anchor="mm", stroke=1)
            if lt > 0.8:
                label(u_, (mx, 76), "the AI: touching grass. finally.", 9 if sq() else 10, (240, 255, 240), anchor="mm", stroke=1)
    return img


SQ_CY["s_victory"] = 235
cue(s_victory, 0.0, "chime")
cue(s_victory, 0.3, "achievement")
cue(s_victory, 1.0, "shing")
for i in range(6):
    cue(s_victory, 0.5 + i * 0.4, "cheer", n=i)

COMMENTS = (
    (0.45, "SourcePlease_v2", (90, 160, 255), "source?", "2.1k"),
    (1.1, "WellAckshually77", (255, 120, 80), "technically tater tots aren't potatoes, they're potato-adjacent--", "-312"),
    (1.8, "ThisGuyThises", (140, 220, 120), "This.", "999"),
    (2.4, None, None, "[removed by moderator]", "."),
    (3.0, "KarmaKarl", (255, 200, 80), "edit: thanks for the gold, kind stranger!", "5"),
    (3.65, "TotallyNotABot", (200, 140, 255), "as a fellow human, i too enjoy touching grass. beep.", "12"),
)


def comment_card(img, y, user, col, body, votes):
    d = ImageDraw.Draw(img)
    if user is None:
        label(img, (20, y + 2), body, 10, (130, 130, 136), stroke=0)
        d.line((10, y - 4, 10, y + 18), fill=(60, 60, 66))
        return 26
    d.ellipse((14, y, 24, y + 10), fill=col)
    d.point((17, y + 4), fill=(20, 20, 24))
    d.point((21, y + 4), fill=(20, 20, 24))
    label(img, (30, y + 1), user, 9, (170, 170, 178), stroke=0)
    lines = wrap(body, pix(10), 220)
    for i, ln in enumerate(lines):
        label(img, (30, y + 14 + i * 13), ln, 10, (236, 236, 240), stroke=0)
    vy = y + 16 + len(lines) * 13
    d.polygon(((32, vy + 6), (36, vy + 1), (40, vy + 6)), fill=ORANGE if not votes.startswith("-") else (90, 90, 96))
    label(img, (45, vy), votes, 9, (170, 170, 178), stroke=0)
    vx = 45 + int(pix(9).getlength(votes)) + 6
    d.polygon(((vx, vy + 1), (vx + 4, vy + 6), (vx + 8, vy + 1)), fill=PERI if votes.startswith("-") else (90, 90, 96))
    label(img, (vx + 16, vy), "Reply", 9, (130, 130, 136), stroke=0)
    d.line((10, y - 4, 10, vy + 8), fill=(60, 60, 66))
    return vy + 14 - y


@shot(7.0)
def s_comments(lt):
    """Meanwhile, in the comments."""
    img = canvas((14, 14, 16))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W, 30), fill=(26, 26, 30))
    d.ellipse((6, 3, 30, 27), fill=ORANGE)
    put(img, gfx.tot_img(k=1), 18, 28)
    label(img, (36, 9), "r/tatertotsvsbots", 11, (240, 240, 244), stroke=0)
    d.rounded_rectangle((200, 8, 260, 22), radius=7, fill=(0, 121, 211))
    label(img, (230, 15), "Join", 9, (255, 255, 255), anchor="mm", stroke=0)
    # the post
    py = 38
    label(img, (12, py), "posted by AgentGarrett  2h", 9, (150, 150, 158), stroke=0)
    for i, ln in enumerate(wrap("Tater tots just ended the AI apocalypse. AMA.", pix(12), 246)):
        label(img, (12, py + 14 + i * 16), ln, 12, (250, 250, 252), stroke=0)
    votes = int(lerp(12000, 42069, ease_out(seg(lt, 0, 4.0))))
    vy = py + 50
    d.rounded_rectangle((12, vy, 92, vy + 16), radius=8, fill=(36, 36, 40))
    d.polygon(((20, vy + 11), (25, vy + 4), (30, vy + 11)), fill=ORANGE)
    label(img, (36, vy + 3), f"{votes / 1000:.1f}k", 9, (240, 240, 244), stroke=0)
    d.polygon(((72, vy + 5), (77, vy + 12), (82, vy + 5)), fill=(120, 120, 128))
    d.rounded_rectangle((98, vy, 184, vy + 16), radius=8, fill=(36, 36, 40))
    label(img, (141, vy + 8), "4.2k comments", 9, (240, 240, 244), anchor="mm", stroke=0)
    d.line((0, vy + 24, W, vy + 24), fill=(40, 40, 44))
    # the comments, piling up; the list scrolls once it runs out of room
    cards = []
    for at, user, col, body, v in COMMENTS:
        if lt > at:
            cards.append((at, user, col, body, v))
    lay = Image.new("RGBA", (W, 900), (0, 0, 0, 0))
    y = 6
    ends = []
    for j, (at, user, col, body, v) in enumerate(cards):
        slide = int(24 * (1 - ease_out(seg(lt, at, at + 0.2)))) if j == len(cards) - 1 else 0
        y += comment_card(lay, y + slide, user, col, body, v) + 8
        ends.append(y)
    view = (W if sq() else H) - (vy + 30)
    after = max(0, (ends[-1] if ends else 0) - view + 30)
    before = max(0, (ends[-2] if len(ends) > 1 else 0) - view + 30)
    scroll = lerp(before, after, ease_out(seg(lt, cards[-1][0], cards[-1][0] + 0.3))) if cards else 0
    img.alpha_composite(lay.crop((0, int(scroll), W, int(scroll) + view)), (0, vy + 30))
    if lt > 4.3:
        flash(img, 0.78 * seg(lt, 4.3, 4.5), (0, 0, 0))
        rise = ease_out(seg(lt, 4.35, 4.65))
        gtot(img, 70, lerp(430, 300, rise) if sq() else lerp(560, 480, rise), k=5, gear=("band",), eyes="side" if int(lt * 2) % 2 == 0 else "left", mouth="flat")
    u_ = ui()
    if lt > 4.4:
        headline(u_, "...WAIT.", Y(200), 30, (255, 255, 255), (0, 0, 0), pop=seg(lt, 4.4, 4.6))
    if lt > 4.9:
        headline(u_, "WHICH ONES ARE THE BOTS??", Y(240), 26, (255, 236, 90), (120, 40, 0), pop=seg(lt, 4.9, 5.15))
    return img


for at, *_ in COMMENTS:
    cue(s_comments, at, "notif")
cue(s_comments, 4.4, "stamp")
cue(s_comments, 4.9, "stamp")
say(s_comments, 5.6, 7.0, "garrett", "...hard to tell.", "top")
SQ_CY["s_comments"] = 135

# =================================================================================================== 10. END CARD

def end_square(lt):
    """The end card for the square: title over Agent Garrett, the tots in a row, the link on the ground."""
    img = canvas()
    img.paste(grad_img(((0, (255, 186, 70)), (0.7, (240, 110, 30)), (1, (150, 40, 20))), W, 10), (0, 0))
    sun_rays(img, lt, 135, 150, col=(255, 236, 170), a=0.22)
    put(img, glow_img(100, (255, 240, 180), 0.4), 135, 150, anchor="center")
    garrett(img, 135, 234, k=2, t=lt, pose="stand", rim_col=(255, 240, 170))
    for i, x in enumerate((30, 78, 192, 240)):
        bob = 1 if math.sin(lt * 7 + i) > 0.5 else 0
        gtot(img, x, 236, k=2, gear=("helmet", "fork") if i % 2 else ("band", "fork"), arms="up" if i in (0, 3) else "down", bob=bob)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 236, W, H), fill=(60, 18, 14))
    d.line((0, 236, W, 236), fill=(255, 190, 110))
    bubble(img, 30, 182, "now go touch grass.", lt - 2.2, size=9, maxw=110, dur=9)
    u_ = ui()
    headline(u_, "TATER-TOTS", 26, 42, (255, 214, 90), (110, 40, 0), pop=seg(lt, 0.1, 0.4), stroke=4)
    if lt > 0.45:
        headline(u_, "vs THE AI APOCALYPSE", 55, 16, (255, 255, 255), (60, 10, 0), pop=seg(lt, 0.45, 0.65))
    if lt > 0.8:
        label(u_, (W // 2, 70), "starring AGENT GARRETT", 10, EYE_G, anchor="mm", stroke=2, stroke_fill=(40, 10, 0))
    if lt > 1.2:
        headline(u_, "nl-veil", 247, 16, (255, 255, 255), (0, 0, 0), pop=seg(lt, 1.2, 1.4), stroke=2)
        label(u_, (W // 2, 262), "github.com/gary23w/nl-veil", 9, (255, 220, 180), anchor="mm", stroke=1)
    return img


@shot(4.0)
def s_end(lt):
    if sq():
        return end_square(lt)
    img = canvas()
    img.paste(grad_img(((0, (255, 186, 70)), (0.6, (240, 110, 30)), (1, (120, 30, 20))), H, 10), (0, 0))
    sun_rays(img, lt, 135, 300, col=(255, 236, 170), a=0.22)
    put(img, glow_img(120, (255, 240, 180), 0.4), 135, 290, anchor="center")
    garrett(img, 135, 368, k=2, t=lt, pose="stand", rim_col=(255, 240, 170))
    for i, x in enumerate((40, 88, 182, 230)):
        bob = 1 if math.sin(lt * 7 + i) > 0.5 else 0
        gtot(img, x, 372, k=2, gear=("helmet", "fork") if i % 2 else ("band", "fork"), arms="up" if i in (0, 3) else "down", bob=bob)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 372, W, H), fill=(60, 18, 14))
    d.line((0, 372, W, 372), fill=(255, 190, 110))
    u_ = ui()
    headline(u_, "TATER-TOTS", 64, 52, (255, 214, 90), (110, 40, 0), pop=seg(lt, 0.1, 0.4), stroke=4)
    if lt > 0.45:
        headline(u_, "vs THE AI APOCALYPSE", 104, 20, (255, 255, 255), (60, 10, 0), pop=seg(lt, 0.45, 0.65))
    if lt > 0.8:
        label(u_, (W // 2, 130), "starring AGENT GARRETT", 11, EYE_G, anchor="mm", stroke=2, stroke_fill=(40, 10, 0))
    if lt > 1.2:
        headline(u_, "nl-veil", 398, 24, (255, 255, 255), (0, 0, 0), pop=seg(lt, 1.2, 1.4))
        label(u_, (W // 2, 420), "github.com/gary23w/nl-veil", 10, (255, 220, 180), anchor="mm", stroke=1)
    if lt > 2.2:
        label(u_, (W // 2, 446), "(now go touch grass)", 10, (200, 200, 200), anchor="mm", stroke=1)
    return img


SQ_CY["s_end"] = 135
cue(s_end, 0.1, "boom", size=0.6)
cue(s_end, 0.12, "chime")
cue(s_end, 1.2, "pop")
cue(s_end, 2.2, "pop")

# ----------------------------------------------------------------------------------------------- music map

MUSIC += [
    (s_hook.t0, s_hook.t0 + FREEZE, "hookrun"),
    (s_lab.t0, s_lab.t0 + 3.35, "lab"),
    (s_lab.t0 + 3.4, s_apocalypse.t0, "dread"),
    (s_apocalypse.t0, s_garrett.t0, "doom"),
    (s_garrett.t0, s_legion.t0, "noir"),
    (s_garrett.t0, s_legion.t0, "rain"),
    (s_legion.t0, s_versus.t0, "march"),
    (s_versus.t0, s_boss.t0, "battle"),
    (s_boss.t0, s_command.t0, "boss"),
    (s_command.t0, s_grass.t0, "dread"),
    (s_grass.t0, s_boom.t0 + 0.05, "finale"),
    (s_victory.t0, s_comments.t0, "victory"),
    (s_comments.t0, s_end.t0, "lofi"),
    (s_end.t0, s_end.t0 + s_end.dur, "theme"),
]

TOTAL = CUR[0]
