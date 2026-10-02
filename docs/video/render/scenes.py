"""The timeline: every shot, every line of dialogue, every sound cue, in order.

A shot is a function draw(img, lt) of its local time; `shot(dur)` places it after the one before. Dialogue and
cues are registered against a shot with local times, so moving a shot moves everything in it.
"""
import math
import random

from PIL import Image, ImageDraw

from gfx import *  # noqa: F401,F403 - the drawing vocabulary
import gfx

SHOTS = []  # (t0, t1, fn, hires)
SAY = []  # (t0, t1, speaker, text, where)
CUES = []  # (t, name, kwargs)
SHAKE = []  # (t, amplitude, duration)
MUSIC = []  # (t0, t1, track)
CUR = [0.0]


def shot(dur, hires=False):
    def deco(fn):
        fn.t0 = CUR[0]
        fn.dur = dur
        SHOTS.append((CUR[0], CUR[0] + dur, fn, hires))
        CUR[0] += dur
        return fn
    return deco


def say(s, a, b, speaker, line, where="bottom"):
    SAY.append((s.t0 + a, s.t0 + b, speaker, line, where))


def cue(s, at, name, **kw):
    CUES.append((s.t0 + at, name, kw))


def shake(s, at, amp=4, dur=0.3):
    SHAKE.append((s.t0 + at, amp, dur))


# ------------------------------------------------------------------------------------------------ shared set pieces

RND = random.Random(42)
SKY_DOTS = [(RND.randrange(20, W - 20), RND.randrange(14, 130), RND.randrange(5, 11), RND.random() * 6, RND.randrange(5)) for _ in range(46)]


def dot_field(img, t, n=None, big=True, eye_on=True, show=1.0):
    """The Corporate Dots hanging in the sky, bobbing; the big one front and centre."""
    lst = SKY_DOTS[: n if n is not None else len(SKY_DOTS)]
    for i, (x, y, r, ph, col) in enumerate(lst):
        if i / max(1, len(lst)) > show:
            continue
        dot(img, x, y + 2 * math.sin(t * 2 + ph), r, col=col, t=t)
    if big:
        dot(img, 240, 70 + 3 * math.sin(t * 1.6), 26, glow=True, eye_on=eye_on, t=t)


def ground_tots(img, t, xs=(170, 205, 240, 275, 310), y=200, k=2, eyes="up", **kw):
    for i, x in enumerate(xs):
        tot(img, x, y, k=k, eyes=eyes, bob=1 if math.sin(t * 6 + i) > 0.6 else 0, hat=(x == 240), **kw)


def black():
    return Image.new("RGBA", (W, H), (0, 0, 0, 255))


def dark(col=(10, 8, 18)):
    return Image.new("RGBA", (W, H), col + (255,))


def counter(img, s, lt, blink=True):
    on = (not blink) or int(lt * 6) % 2 == 0
    box(img, 250, 8, 470, 30, top=(120, 20, 30), bottom=(70, 10, 20), border=(255, 255, 255), inner=(255, 120, 130))
    if on:
        text(img, (360, 19), s, 12, (255, 255, 255), anchor="mm")


# =================================================================================================== 1. COLD OPEN

@shot(2.0)
def s_presents(img, lt):
    img = black()
    a = seg(lt, 0.2, 0.7) * (1 - seg(lt, 1.5, 1.9))
    text(img, (W // 2, H // 2), "NL-VEIL PRESENTS...", 16, (255, 236, 200), anchor="mm", alpha=a, stroke=0)
    return img


TRAILER = ((0.2, "IN A WORLD..."), (1.4, "...OVERRUN BY AI AGENTS..."), (2.6, "...ONE SIDE DISH..."), (3.8, "...STOOD BETWEEN HUMANITY"), (5.0, "AND THE AI APOCALYPSE."))


@shot(6.4)
def s_trailer(img, lt):
    img = black()
    for i, (at, line) in enumerate(TRAILER):
        if at <= lt < (TRAILER[i + 1][0] if i + 1 < len(TRAILER) else 6.4):
            a = seg(lt, at, at + 0.25) * (1 - seg(lt, at + 1.0, at + 1.2) if i + 1 < len(TRAILER) else 1)
            col = (255, 90, 90) if i == len(TRAILER) - 1 else (235, 225, 210)
            text(img, (W // 2, H // 2), line, f=big(30 if i < len(TRAILER) - 1 else 36), fill=col, anchor="mm", stroke=0, alpha=a)
    if lt > 5.0:
        for i in range(6):
            x = 60 + i * 72
            dot(img, x, 50 + 6 * math.sin(lt * 3 + i), 8, col=i % 5, eye_on=int(lt * 4 + i) % 3 != 0, t=lt)
    return img


for at, _ in TRAILER:
    cue(s_trailer, at, "braam")


@shot(2.8)
def s_enter(img, lt):
    img = meadow().copy()
    walk = lt < 1.5
    x = lerp(-30, 240, ease_out(seg(lt, 0, 1.5)) if lt < 1.5 else 1)
    x = lerp(-30, 240, seg(lt, 0, 1.5))
    tot(img, x, 214, k=3, hat=True, walk_t=lt if walk else None, arms="wave" if lt > 1.6 else "down", mouth="open" if 1.6 < lt < 2.2 and int(lt * 8) % 2 else "smile")
    return img


say(s_enter, 1.6, 2.8, "gary", "hi. i'm gary.")
for i in range(9):
    cue(s_enter, i * 0.17, "pip", n=i)

EXTRAS = sorted(RND.sample(list(range(14, 470, 26)), 17))


@shot(3.4)
def s_crowd(img, lt):
    img = meadow().copy()
    # the extras: in from the nearest edge, then (told the limit) out to the right, single file
    for i, x in enumerate(EXTRAS):
        arrive = 0.9 + i * 0.03
        start = -20 if x < 240 else W + 20
        if lt < arrive:
            continue
        if lt < arrive + 0.35:
            xx = lerp(start, x, (lt - arrive) / 0.35)
            tot(img, xx, 222, k=2, walk_t=lt)
        else:
            cheer = lt > 1.6 and (i + int(lt * 6)) % 3 == 0
            tot(img, x, 222 - (2 if cheer else 0), k=2, eyes="up" if lt > 1.5 else "normal", arms="up" if lt > 1.6 else "down")
    tot(img, lerp(-20, 170, seg(lt, 0, 0.5)), 214, k=3, walk_t=lt if lt < 0.5 else None)
    tot(img, lerp(W + 20, 310, seg(lt, 0.3, 0.8)), 214, k=3, walk_t=lt if 0.3 < lt < 0.8 else None)
    tot(img, 240, 214, k=3, hat=True, eyes="side" if lt > 1.5 else "normal")
    if lt > 1.5:
        box(img, 250, 8, 470, 44, top=(40, 90, 40), bottom=(18, 50, 20), border=(255, 255, 255), inner=(150, 240, 150))
        text(img, (360, 19), "TATER-TOTS: 20 / 24++", 12, (255, 255, 255), anchor="mm")
        text(img, (360, 34), "(your setup decides the ++)", 10, (200, 255, 200), anchor="mm")
    return img


say(s_crowd, 2.0, 3.4, "tot", "we're gonna need a bigger fryer.")
cue(s_crowd, 0.0, "pip", n=1)
cue(s_crowd, 0.3, "pip", n=2)
for i in range(8):
    cue(s_crowd, 0.9 + i * 0.06, "pip", n=i)
cue(s_crowd, 1.5, "achievement")


@shot(2.0)
def s_title(img, lt):
    img = meadow().copy()
    tint(img, (20, 10, 30), 0.25)
    for i, x in enumerate((170, 240, 310)):
        tot(img, x, 230, k=2, hat=(x == 240), bob=1 if math.sin(lt * 8 + i) > 0 else 0)
    y = lerp(-60, 92, ease_out(seg(lt, 0, 0.3)))
    sc = bounce(seg(lt, 0.3, 0.6))
    f = big(int(64 * sc))
    text(img, (W // 2, y), "TATER-TOTS", f=f, fill=(255, 210, 90), anchor="mm", stroke=3, stroke_fill=(110, 50, 10))
    sub = "bite-sized agents. full-sized results."
    n = int(max(0, lt - 0.6) * 30)
    text(img, (W // 2, 150), sub[:n], 15, (255, 255, 255), anchor="mm", stroke=2, stroke_fill=(60, 30, 10))
    for j in range(5):
        sparkle(img, 140 + j * 50, 60 + (j % 2) * 50, lt - 0.35 - j * 0.08)
    return img


cue(s_title, 0.3, "boom", size=0.6)
cue(s_title, 0.32, "chime")


@shot(2.6)
def s_dostuff(img, lt):
    img = meadow().copy()
    tot(img, 240, 230, k=6, hat=True, arms="up" if lt > 0.2 else "down", mouth="open" if int(lt * 8) % 2 and lt < 0.8 else "smile")
    return img


say(s_dostuff, 0.1, 1.4, "gary", "we do stuff.")
say(s_dostuff, 1.45, 2.6, "gary", "(we byte back.)")

# =================================================================================================== 2. DOTS

@shot(3.4)
def s_desktop(img, lt):
    """A computer at home, quiet; the dots are already there, and turn to look."""
    img = dark((14, 12, 20))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((40, 14, 440, 238), 8, fill=(40, 40, 50))
    bands(Image.new("RGBA", (1, 1)), (0, 0, 0), (0, 0, 0), 0, 1)
    sx0, sy0, sx1, sy1 = 50, 22, 430, 218
    for i in range(10):
        a_, b_ = sy0 + (sy1 - sy0) * i // 10, sy0 + (sy1 - sy0) * (i + 1) // 10
        d.rectangle((sx0, a_, sx1, b_), fill=mix((40, 90, 170), (90, 150, 220), i / 9))
    d.rectangle((sx0, sy1 - 14, sx1, sy1), fill=(24, 28, 40))
    d.rectangle((sx0 + 4, sy1 - 11, sx0 + 14, sy1 - 3), fill=(90, 160, 255))
    d.rectangle((200, 236, 280, 246), fill=(40, 40, 50))
    d.rectangle((170, 246, 310, 252), fill=(50, 50, 62))
    for i, name in enumerate(("projects", "music", "notes", "games")):
        fx, fy = sx0 + 16, sy0 + 12 + i * 40
        d.rectangle((fx, fy + 3, fx + 22, fy + 18), fill=(250, 210, 90), outline=(170, 130, 30))
        d.rectangle((fx, fy, fx + 9, fy + 4), fill=(250, 210, 90))
        text(img, (fx + 11, fy + 21), name, 9, (255, 255, 255), anchor="ma", stroke=1)
    # the dots: peeking from behind a folder, sitting in the tray, hanging in a corner
    peek = ease_out(seg(lt, 0.4, 0.8)) * 10
    on = [lt > 1.0, lt > 1.2, lt > 1.4]
    dot(img, sx0 + 30 + peek, sy0 + 62, 7, col=1, eye_on=on[0])
    dot(img, sx1 - 20, sy1 - 7, 5, col=2, eye_on=on[1])
    dot(img, sx1 - 24, sy0 + 22, 9, col=3, eye_on=on[2])
    dot(img, 250, 120 + 2 * math.sin(lt * 3), 14, col=0, eye_on=lt > 0.2)
    if lt > 0.2:
        text(img, (W // 2, 258), "they hide in plain sight.", 13, (255, 230, 230), anchor="mm", stroke=2)
    if lt > 1.6:
        text(img, (sx1 - 8, sy0 + 50), "Always on.", 12, (255, 255, 255), anchor="ra", stroke=2)
    if lt > 2.0:
        text(img, (sx1 - 8, sy0 + 66), "Always watching.", 12, (255, 220, 230), anchor="ra", stroke=2)
    if lt > 2.5:
        text(img, (sx1 - 8, sy0 + 82), "Never actually done.", 12, (255, 236, 150), anchor="ra", stroke=2)
    return img


for i, at in enumerate((1.0, 1.2, 1.4)):
    cue(s_desktop, at, "pip", n=12 + i, low=True)


@shot(1.6)
def s_warn(img, lt):
    img = meadow().copy()
    tot(img, 240, 230, k=6, hat=True, eyes="up", mouth="o")
    tint(img, (255, 0, 20), 0.35 + 0.25 * math.sin(lt * 20))
    d = ImageDraw.Draw(img)
    for y0 in (0, H - 22):
        d.rectangle((0, y0, W, y0 + 22), fill=(30, 0, 0))
        for x in range(-40, W + 40, 24):
            off = int(lt * 60) % 24
            d.polygon(((x + off, y0), (x + off + 12, y0), (x + off - 10, y0 + 22), (x + off - 22, y0 + 22)), fill=(250, 210, 40))
    if int(lt * 6) % 2 == 0:
        text(img, (W // 2, H // 2 - 46), "!! WARNING !!", f=big(48), fill=(255, 236, 60), anchor="mm", stroke=3, stroke_fill=(120, 0, 0))
    text(img, (W // 2, H // 2 + 6), "AI APOCALYPSE DETECTED", f=big(30), fill=(255, 255, 255), anchor="mm", stroke=3, stroke_fill=(120, 0, 0))
    return img


cue(s_warn, 0.0, "siren")


RUNNERS = [(RND.randrange(260, 470), RND.choice(((60, 120, 220), (220, 70, 60), (90, 180, 90), (230, 200, 60), (180, 120, 220))), RND.uniform(55, 85)) for _ in range(9)]
SKYLINE = [(x, RND.randrange(40, 120), RND.randrange(18, 34)) for x in range(-10, W, 30)]
ZAPS = ((0.7, 0), (1.3, 2), (1.9, 4), (2.5, 1))


def person(img, x, y, shirt, t, scared=True):
    d = ImageDraw.Draw(img)
    ph = int(t * 12) % 2
    d.line((x, y - 3, x - 2 if ph else x + 2, y), fill=(40, 30, 30))
    d.line((x, y - 3, x + 2 if ph else x - 2, y), fill=(40, 30, 30))
    d.rectangle((x - 1, y - 7, x + 1, y - 3), fill=shirt)
    d.rectangle((x - 1, y - 10, x + 1, y - 8), fill=(240, 196, 160))
    if scared:
        d.line((x - 1, y - 7, x - 3, y - 11), fill=shirt)
        d.line((x + 1, y - 7, x + 3, y - 11), fill=shirt)


@shot(4.8)
def s_apocalypse(img, lt):
    """The dots turned on us: sentries over a burning city, people running. Only a side dish can stop them."""
    img = Image.new("RGBA", (W, H))
    bands(img, (40, 6, 10), (150, 50, 24), 0, 200, 10)
    d = ImageDraw.Draw(img)
    for x, h, w in SKYLINE:
        d.rectangle((x, 200 - h, x + w, 200), fill=(26, 14, 18))
        d.polygon(((x, 200 - h), (x + w * 0.4, 200 - h - 6), (x + w * 0.7, 200 - h + 3), (x + w, 200 - h)), fill=(26, 14, 18))
        for wy in range(200 - h + 8, 196, 9):
            for wx in range(x + 3, x + w - 3, 7):
                if (wx * 7 + wy * 3) % 5 == 0:
                    d.rectangle((wx, wy, wx + 2, wy + 3), fill=(255, 170, 60))
    for i, fx in enumerate((70, 210, 380)):
        fh = 10 + 5 * math.sin(lt * 14 + i)
        d.polygon(((fx - 7, 200), (fx + 7, 200), (fx, 200 - fh)), fill=(255, 120, 30))
        d.polygon(((fx - 4, 200), (fx + 4, 200), (fx, 200 - fh * 0.6)), fill=(255, 220, 90))
    d.rectangle((0, 200, W, H), fill=(44, 30, 34))
    for i, (x0, shirt, sp) in enumerate(RUNNERS):
        x = x0 - lt * sp
        jump = 0
        for at, k in ZAPS:
            u = lt - at - 0.12
            if 0 <= u < 0.35 and abs((RUNNERS[k][0] - (at + 0.12) * RUNNERS[k][2]) - x) < 40:
                jump = math.sin(u / 0.35 * math.pi) * 12
        if x > -10:
            person(img, x, 214 - jump, shirt, lt + i)
    for i in range(5):
        sx = 60 + i * 90 + 30 * math.sin(lt * 0.9 + i)
        sy = 50 + (i % 2) * 22
        scan_cone(img, sx, sy, math.pi / 2 + 0.5 * math.sin(lt * 1.4 + i * 1.3), 170)
        dot(img, sx, sy, 10, col=i, t=lt + i)
    for at, k in ZAPS:
        u = lt - at
        i = (k * 2) % 5
        sx = 60 + i * 90 + 30 * math.sin(lt * 0.9 + i)
        sy = 50 + (i % 2) * 22
        tx = RUNNERS[k][0] - at * RUNNERS[k][2] + 18
        if 0 <= u < 0.12:
            d2 = ImageDraw.Draw(img)
            d2.line((sx, sy, tx, 212), fill=(255, 60, 70), width=3)
            d2.line((sx, sy, tx, 212), fill=(255, 230, 230), width=1)
        explosion(img, tx, 210, u - 0.1, 14, seed=k + 3)
    if 0.3 < lt < 2.9:
        text(img, (W // 2, 120), "THE DOTS TURNED ON US.", f=big(28), fill=(255, 80, 90), anchor="mm", stroke=3, stroke_fill=(30, 0, 0))
    if 1.5 < lt < 2.9:
        text(img, (W // 2, 148), "they hover. they scan. they patrol.", 13, (255, 230, 230), anchor="mm", stroke=2)
    if lt > 2.9:
        tint(img, (0, 0, 0), 0.45)
        text(img, (W // 2, 92), "THE ONLY THING THAT CAN STOP THEM...", f=big(22), fill=(255, 255, 255), anchor="mm", stroke=3, stroke_fill=(0, 0, 0))
    if lt > 3.8:
        s_ = bounce(seg(lt, 3.8, 4.05))
        text(img, (W // 2, 128), "...IS A SIDE DISH.", f=big(int(32 * s_)), fill=(255, 210, 90), anchor="mm", stroke=3, stroke_fill=(110, 40, 0))
        rise = ease_out(seg(lt, 3.8, 4.1))
        tot(img, 240, lerp(290, 232, rise), k=3, hat=True, glow_eyes=True)
    return img


cue(s_apocalypse, 0.3, "braam")
for at, _ in ZAPS:
    cue(s_apocalypse, at, "laser")
    cue(s_apocalypse, at + 0.1, "boom", size=0.35)
    shake(s_apocalypse, at + 0.1, 2, 0.2)
cue(s_apocalypse, 2.9, "braam")
cue(s_apocalypse, 3.8, "stamp")
cue(s_apocalypse, 3.85, "chime")


@shot(2.8)
def s_descend(img, lt):
    img = battlefield().copy()
    show = seg(lt, 0.8, 1.6)
    dot_field(img, lt, big=False, show=show)
    y = lerp(-40, 70, ease_out(seg(lt, 0, 0.9)))
    dot(img, 240, y, 26, glow=True, t=lt)
    ground_tots(img, lt)
    if lt > 1.2:
        hp_bar(img, 16, 26, 180, ease_out(seg(lt, 1.2, 1.6)), "THE DOT UPRISING")
    if lt > 1.6:
        text(img, (16, 46), "Very sophisticated.", 13, (255, 220, 230))
    if lt > 2.1:
        text(img, (16, 62), "Very subscription.", 13, (255, 236, 150))
    return img


cue(s_descend, 0.0, "whoosh")
cue(s_descend, 0.85, "boom", size=0.5)
shake(s_descend, 0.85, 3, 0.3)
for i in range(6):
    cue(s_descend, 0.8 + i * 0.13, "pip", n=10 + i, low=True)


@shot(1.6)
def s_ohno(img, lt):
    img = battlefield().copy()
    dot_field(img, lt + 3)
    tot(img, 200, 214, k=4, hat=True, eyes="up", mouth="o")
    tot(img, 290, 214, k=3, eyes="side" if lt > 0.8 else "up", mouth="flat")
    return img


say(s_ohno, 0.0, 0.75, "gary", "oh no.")
say(s_ohno, 0.8, 1.6, "tot", "anyway.")


@shot(1.2)
def s_vs(img, lt):
    img = Image.new("RGBA", (W, H))
    bands(img, (255, 170, 60), (180, 70, 20), 0, H, 8)
    right = Image.new("RGBA", (W, H))
    bands(right, (200, 206, 220), (70, 76, 96), 0, H, 8)
    mask = Image.new("L", (W, H), 0)
    sl = lerp(W + 60, 0, ease_out(seg(lt, 0, 0.15)))
    ImageDraw.Draw(mask).polygon(((W / 2 + 30 + sl, 0), (W, 0), (W, H), (W / 2 - 30 + sl, H)), fill=255)
    img.paste(right, (0, 0), mask)
    tot(img, 120, 220, k=6, hat=True, arms="up")
    dot(img, 370, 130, 52, glow=True)
    text(img, (120, 40), "TOTS", f=big(40), fill=(255, 240, 200), anchor="mm", stroke=3, stroke_fill=(100, 40, 0))
    text(img, (370, 40), "DOTS", f=big(40), fill=(230, 236, 250), anchor="mm", stroke=3, stroke_fill=(30, 30, 50))
    vs = bounce(seg(lt, 0.1, 0.35))
    text(img, (W // 2, H // 2), "VS", f=big(int(56 * vs)), fill=(255, 255, 255), anchor="mm", stroke=4, stroke_fill=(0, 0, 0))
    if lt > 0.6:
        fs = bounce(seg(lt, 0.6, 0.85))
        text(img, (W // 2, H - 40), "FIGHT!", f=big(int(64 * fs)), fill=(255, 230, 60), anchor="mm", stroke=4, stroke_fill=(180, 20, 20))
    return img


cue(s_vs, 0.0, "whoosh")
cue(s_vs, 0.1, "boom", size=0.4)
cue(s_vs, 0.6, "fight")
shake(s_vs, 0.6, 3, 0.25)

ATTACKS = ((0.0, "DOT ATTACK: ENTERPRISE ROADMAP", 175), (0.8, "DOT ATTACK: VENDOR LOCK-IN", 300), (1.6, "DOT ATTACK: PLEASE UPGRADE YOUR PLAN", 240))
HIT_BY = {0: 0, 1: 0, 3: 1, 4: 1, 2: 2}  # which attack sends which tot flying


@shot(2.7)
def s_attacks(img, lt):
    img = battlefield().copy()
    dot_field(img, lt + 5)
    hp_bar(img, 16, 26, 180, 1.0, "DOT SENTRIES")
    xs = (160, 200, 240, 280, 320)
    for i, x in enumerate(xs):
        at, _, tx = ATTACKS[HIT_BY[i]]
        h = at + 0.15
        if lt < h:
            tot(img, x, 200, k=2, eyes="up", mouth="o", hat=(i == 2))
        else:
            u = lt - h
            vx = (x - tx) * 2.2 + (40 if i % 2 else -40)
            xx, yy = x + vx * u, 200 - (260 * u - 380 * u * u)
            if yy < H + 40:
                tot(img, xx, yy, k=2, glow=False, angle=int(u * 900) % 360, mouth="open", eyes="closed", hat=(i == 2))
    for at, name, tx in ATTACKS:
        u = lt - at
        if 0 <= u < 0.7:
            banner(img, name, u, y=46, size=15)
        if 0.05 <= u < 0.2:
            d = ImageDraw.Draw(img)
            d.line((240, 80, tx, 196), fill=(255, 80, 90), width=5)
            d.line((240, 80, tx, 196), fill=(255, 230, 230), width=2)
        explosion(img, tx, 192, u - 0.15, 42, seed=int(at * 10))
    if lt > 1.85:
        s = bounce(seg(lt, 1.85, 2.1))
        text(img, (W // 2, 120), "CRITICAL HIT!", f=big(int(46 * s)), fill=(255, 240, 80), anchor="mm", stroke=3, stroke_fill=(200, 30, 30))
    return img


for at, _, _ in ATTACKS:
    cue(s_attacks, at, "laser")
    cue(s_attacks, at + 0.15, "boom", size=0.8)
    shake(s_attacks, at + 0.15, 5, 0.35)
cue(s_attacks, 1.85, "crit")


@shot(1.6)
def s_rude(img, lt):
    img = battlefield().copy()
    dot_field(img, lt + 8)
    # someone else, upside down in the background, legs going
    tot(img, 380, 186, k=2, glow=False, angle=180, walk_t=lt, eyes="closed", mouth="flat")
    if lt < 0.5:
        tot(img, 240, 210, k=4, glow=False, angle=90, eyes="closed", mouth="flat", hat=False)
    else:
        hop = math.sin(seg(lt, 0.5, 0.75) * math.pi) * 8
        tot(img, 240, 214 - hop, k=4, eyes="normal", mouth="flat", arms="down")
    for i in range(4):
        sparkle(img, 220 + i * 14, 205, lt - 0.7 - i * 0.04, (200, 190, 170))
    return img


say(s_rude, 0.8, 1.6, "tot", "rude.")
cue(s_rude, 0.5, "pip", n=3)


@shot(4.0)
def s_tutorial(img, lt):
    img = battlefield().copy()
    dot_field(img, lt + 10)
    tot(img, 240, 214, k=4, mouth="flat", eyes="up" if lt < 1.6 else "normal")
    box(img, 60, 50, 420, 118, top=(20, 70, 40), bottom=(10, 40, 24), inner=(120, 230, 150))
    text(img, (72, 58), "ITERATION 1:", 13, (255, 255, 255))
    if lt < 1.6:
        text(img, (176, 58), "REGRESSED?", 13, (255, 110, 120))
    if lt > 0.6:
        line = "judge: a failed attempt that changed nothing is SAME."
        n = int((lt - 0.6) * 40)
        for i, part in enumerate(wrap(line[:n], pix(12), 330)):
            text(img, (72, 78 + 15 * i), part, 12, (170, 240, 190))
    if lt > 1.6:
        s = bounce(seg(lt, 1.6, 1.85))
        text(img, (230, 58), "SAME.", f=big(int(22 * s)), fill=(120, 255, 160), anchor="mm", stroke=2, stroke_fill=(0, 60, 20))
    return img


cue(s_tutorial, 1.6, "stamp")
say(s_tutorial, 1.95, 2.8, "tot", "...ok that's fair.")
say(s_tutorial, 2.85, 4.0, "tot", "it's not a bug. it's a fry-ture.")

# =================================================================================================== 3. THE CHIEF DOT OFFICER

@shot(2.2)
def s_freeze(img, lt):
    img = battlefield().copy()
    dot_field(img, 11)
    tot(img, 200, 214, k=3, hat=True, eyes="side")
    tot(img, 150, 214, k=3, eyes="side", mouth="o")
    img = desaturate(img, 0.85 if lt < 1.7 else 0.85 * (1 - seg(lt, 1.7, 1.9)))
    x = lerp(W + 40, 380, ease_out(seg(lt, 0.2, 1.6)))
    cdo(img, x, 214, k=3, silhouette=lt < 1.7)
    if 1.7 <= lt < 1.85:
        flash(img, 0.6)
    return img


for i in range(4):
    cue(s_freeze, 0.2 + i * 0.4, "step")


@shot(2.4)
def s_cdo_title(img, lt):
    img = battlefield().copy()
    dot_field(img, 12 + lt)
    tint(img, (10, 0, 20), 0.45)
    cdo(img, 370, 214, k=3)
    text(img, (24, 70), "THE CHIEF DOT OFFICER", 18, (210, 150, 255), stroke=2, stroke_fill=(30, 0, 50))
    if lt > 0.6:
        text(img, (24, 98), "VISIONARY???" if lt > 1.35 else "VISIONARY", 16, (255, 230, 120), stroke=2)
    if lt > 1.45:
        text(img, (24, 120), "(it's a donut)", 12, (200, 200, 220))
    if 1.2 <= lt < 1.45:
        img = glitch(img, 1.0, int(lt * 40))
    return img


cue(s_cdo_title, 0.0, "stamp")
cue(s_cdo_title, 0.6, "stamp")
cue(s_cdo_title, 1.2, "glitch")


@shot(2.4)
def s_behold(img, lt):
    img = battlefield().copy()
    dot_field(img, 14 + lt)
    cdo(img, 300, 214, k=3, arm="raise" if lt > 0.05 else "down", mouth="open" if int(lt * 7) % 2 else "smirk")
    z = 1 + 0.6 * ease_out(seg(lt, 0.8, 1.1))
    if z > 1.001:
        cw, ch = int(W / z), int(H / z)
        cx, cy = 300, 130
        x0 = max(0, min(W - cw, int(cx - cw / 2)))
        y0 = max(0, min(H - ch, int(cy - ch / 2)))
        img = img.crop((x0, y0, x0 + cw, y0 + ch)).resize((W, H), Image.NEAREST)
    return img


say(s_behold, 0.0, 0.8, "cdo", "Behold.")
say(s_behold, 1.0, 2.4, "cdo", "The future of agents.")
cue(s_behold, 0.85, "boom", size=0.4)
cue(s_behold, 0.85, "choir")


@shot(4.6)
def s_circle(img, lt):
    img = battlefield().copy()
    dot_field(img, 16 + lt, big=False)
    dot(img, 300, 110 + 2 * math.sin(lt * 2), 16, glow=True)
    cdo(img, 400, 214, k=3)
    eyes = "up" if lt < 0.4 else "side" if lt < 0.8 else "normal"
    tot(img, 200, 214, k=4, hat=True, eyes=eyes, mouth="flat")
    tot(img, 130, 214, k=3, eyes="side" if lt > 1.4 else "up", mouth="o" if 1.5 < lt < 2.2 else "smile")
    return img


say(s_circle, 0.2, 1.3, "gary", "...it's a donut.")
say(s_circle, 1.5, 2.2, "tot", "we're potatoes.")
say(s_circle, 2.25, 2.9, "gary", "exactly.")
say(s_circle, 2.95, 4.6, "tot", "donuts and potatoes: both fried. only one is open source.")


def melting_badge(img, x, y, u):
    """An open-source badge going soft: drips run off it and it turns to a gold coin."""
    d = ImageDraw.Draw(img)
    col = mix((90, 200, 110), (236, 192, 64), seg(u, 0.4, 0.9))
    r = 13
    sag = int(6 * ease_in(u))
    d.ellipse((x - r, y - r + sag // 2, x + r, y + r + sag), fill=col, outline=(30, 30, 30))
    for i, dx in enumerate((-9, -3, 4, 10)):
        ln = int(ease_in(seg(u, 0.1 + i * 0.1, 0.9)) * (14 + 6 * (i % 2)))
        if ln > 0:
            d.line((x + dx, y + r - 2 + sag, x + dx, y + r - 2 + sag + ln), fill=col, width=2)
            d.ellipse((x + dx - 2, y + r + sag + ln - 3, x + dx + 2, y + r + sag + ln + 1), fill=col)
    glyph = "</>" if u < 0.6 else "$"
    text(img, (x, y + sag // 2 + 1), glyph, 11 if u < 0.6 else 15, (20, 40, 20) if u < 0.6 else (110, 70, 0), anchor="mm", stroke=0)


@shot(2.6)
def s_card(img, lt):
    img = battlefield().copy()
    dot_field(img, 18 + lt)
    cdo(img, 400, 214, k=3)
    tint(img, (0, 0, 0), 0.45)
    box(img, 30, 60, 320, 170, top=(40, 30, 80), bottom=(16, 10, 40), inner=(200, 160, 255))
    text(img, (44, 70), "CHIEF DOT OFFICER", 13, (255, 255, 255))
    text(img, (250, 70), "LV 99", 13, (255, 230, 120))
    text(img, (44, 94), "OLD CLASS:", 12, (180, 180, 200))
    text(img, (130, 94), "OPEN-SOURCE HACKER", 12, (140, 240, 160))
    if lt > 0.8:
        text(img, (44, 116), "NEW CLASS:", 12, (180, 180, 200))
        text(img, (130, 116), "CORPORATE DOT WIZARD", 12, (220, 150, 255))
    text(img, (44, 140), "OPENNESS  3      CAPE  999", 12, (200, 200, 220))
    if 0.8 <= lt < 1.0:
        img = glitch(img, 0.8, int(lt * 50))
    melting_badge(img, 400, 28, seg(lt, 0.5, 1.9))
    if lt > 1.3:
        sl = ease_out(seg(lt, 1.3, 1.5))
        x0 = int(lerp(-200, 30, sl))
        box(img, x0, 184, x0 + 186, 220, top=(30, 30, 30), bottom=(10, 10, 10), inner=(236, 192, 64))
        trophy(img, x0 + 10, 194)
        text(img, (x0 + 32, 188), "ACHIEVEMENT UNLOCKED", 10, (236, 192, 64))
        text(img, (x0 + 32, 202), "SOLD OUT?", 13, (255, 255, 255))
    return img


cue(s_card, 0.8, "glitch")
cue(s_card, 1.3, "achievement")


@shot(5.8)
def s_claim(img, lt):
    img = battlefield().copy()
    dot_field(img, 20 + lt)
    cdo(img, 380, 214, k=3, arm="point" if lt < 1.2 else "down", mouth="open" if lt < 1.2 and int(lt * 7) % 2 else "smirk" if lt < 2.4 else "flat")
    tot(img, 160, 214, k=4, hat=True, arms="point" if lt > 2.4 else "down", mouth="flat" if lt < 1.2 else "smile")
    return img


say(s_claim, 0.0, 1.2, "cdo", "Our agent completed the task.")
say(s_claim, 1.25, 2.35, "gary", "show me the tool result.")
say(s_claim, 2.4, 3.6, "gary", "a claim of work is not work.")
say(s_claim, 3.65, 4.6, "cdo", "...it works on my machine.")
say(s_claim, 4.65, 5.8, "gary", "we work with your machine OFF.")


def tumbleweed(img, x, y, t, chrome=False):
    if chrome:
        dot(img, x, y, 7, eye=False)
        return
    d = ImageDraw.Draw(img)
    for i in range(6):
        a = t * 8 + i
        d.arc((x - 9, y - 9, x + 9, y + 9), math.degrees(a), math.degrees(a) + 140, fill=(150, 110, 60))
        d.arc((x - 6, y - 7, x + 7, y + 6), math.degrees(-a) + 30 * i, math.degrees(-a) + 30 * i + 100, fill=(120, 86, 46))


@shot(3.5)
def s_openit(img, lt):
    img = battlefield().copy()
    dot_field(img, 22 + lt)
    cdo(img, 390, 214, k=3, mouth="flat")
    look = "side" if 2.4 < lt < 2.6 else "left" if 2.6 <= lt < 2.8 else "side" if lt >= 2.8 else "up"
    tot(img, 150, 214, k=3, hat=True, eyes=look)
    tot(img, 230, 214, k=2, eyes="up" if lt < 2.4 else ("left" if lt < 2.7 else "side"), mouth="open" if lt < 1.2 and int(lt * 8) % 2 else "smile")
    tot(img, 100, 214, k=3, eyes=look)
    if 1.2 < lt < 2.5:
        tumbleweed(img, lerp(W + 20, -30, seg(lt, 1.2, 2.3)), 204 - abs(math.sin(lt * 9)) * 6, lt)
    if 1.6 < lt < 2.9:
        tumbleweed(img, lerp(W + 20, -30, seg(lt, 1.6, 2.7)), 206 - abs(math.sin(lt * 11)) * 4, lt, chrome=True)
    if 1.2 < lt < 2.4:
        d = ImageDraw.Draw(img)
        for i in range(5):
            y = 120 + i * 18
            x = (W - ((lt - 1.2) * 600 + i * 90)) % (W + 80) - 40
            d.line((x, y, x + 30, y), fill=(220, 210, 230))
    return img


say(s_openit, 0.0, 1.2, "tot", "are you gonna open source it?")
say(s_openit, 1.5, 2.35, "cdo", "...")
say(s_openit, 2.8, 3.5, "tot", "get him.")
cue(s_openit, 1.2, "wind")

# =================================================================================================== 4. THE TOTS AWAKEN

@shot(2.6)
def s_awaken(img, lt):
    img = dark((14, 8, 6))
    on = lt > 0.5
    g = seg(lt, 0.5, 1.4)
    if g > 0:
        put(img, glow_img(int(60 + 60 * g), (255, 200, 90), 0.4 + 0.4 * g), 240, 170, anchor="center")
    tot(img, 240, 290, k=8, glow=False, glow_eyes=on, mouth="flat" if not on else "smile")
    if lt > 0.9 and int(lt * 5) % 2 == 0:
        text(img, (W // 2, 26), "MIT LICENSE DETECTED", f=mono(14), fill=(120, 255, 140), anchor="mm", stroke=1, stroke_fill=(0, 40, 0))
    if lt > 1.5:
        s = bounce(seg(lt, 1.5, 1.8))
        text(img, (W // 2, 60), "TATER-TOTS ARE ONLINE.", f=big(int(34 * s)), fill=(255, 214, 90), anchor="mm", stroke=3, stroke_fill=(90, 40, 0))
    return img


cue(s_awaken, 0.5, "powerup")
cue(s_awaken, 1.5, "chime")


@shot(1.3)
def s_lightup(img, lt):
    img = battlefield().copy()
    tint(img, (0, 0, 0), 0.5)
    for i, x in enumerate((160, 240, 320)):
        lit = lt > i * 0.3
        if lit:
            put(img, glow_img(40, (255, 200, 90), 0.6), x, 170, anchor="center")
        tot(img, x, 214, k=3, glow=False, glow_eyes=lit, hat=(x == 240))
    return img


for i in range(3):
    cue(s_lightup, i * 0.3, "pip", n=20 + i * 3)

CARDS = [("commit 3f9a2c1 fork()", 0.3, (338, 40)), ("PR #42 +4,218 -12", 0.7, (338, 70)), ("fork: tater/nl-veil", 1.1, (338, 100)),
         ("commit 81be0d7 feel()", 1.4, (338, 130)), ("PR #43 tots > dots", 1.8, (338, 160)), ("fork: crispy/nl-veil", 2.1, (40, 190))]


@shot(2.6)
def s_terminal(img, lt):
    img = dark((12, 10, 20))
    d = ImageDraw.Draw(img)
    d.rectangle((20, 40, 330, 176), fill=(6, 6, 10), outline=(120, 120, 150))
    d.rectangle((20, 40, 330, 52), fill=(40, 40, 60))
    for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        d.ellipse((26 + i * 10, 43, 32 + i * 10, 49), fill=c)
    cmd = '$ veil --tater deploy "save humanity" --pace 5'
    n = int(lt * 44)
    lines = [cmd[:n]]
    if n > len(cmd) + 4:
        lines.append("uploading veil-tots into YOUR account...")
    if n > len(cmd) + 24:
        lines.append("Gary deployed (every 5s, up to 3 minds)")
    if n > len(cmd) + 40:
        lines.append("r1 pick   find the big one's weak point")
    y = 58
    for ln in lines:
        for part in wrap(ln, mono(10), 298):
            text(img, (26, y), part, f=mono(10), fill=(140, 255, 160), stroke=0)
            y += 14
    for s, at, (x, yy) in CARDS:
        if lt > at:
            u = ease_out(seg(lt, at, at + 0.25))
            xx = lerp(W + 20 if x > 200 else -160, x, u)
            xx = min(xx, W - 140) if x > 200 else xx
            box(img, int(xx), yy, int(xx) + 132, yy + 22, top=(30, 50, 40), bottom=(14, 30, 22), inner=(90, 200, 120))
            text(img, (int(xx) + 7, yy + 6), s, 10, (200, 255, 210))
    for i in range(10):
        x = (lt * 90 + i * 52) % (W + 40) - 20
        tot(img, x, 266, k=1, walk_t=lt + i)
    return img


for i, (_, at, _) in enumerate(CARDS):
    cue(s_terminal, at, "pip", n=30 + i)


@shot(1.9)
def s_stats(img, lt):
    img = dark((10, 8, 22))
    box(img, 16, 30, 232, 170, top=(40, 30, 10), bottom=(20, 14, 4), inner=(255, 200, 90))
    for i, (name, top) in enumerate((("TRANSPARENCY", 999), ("HACKABILITY", 999), ("WARMTH", 9999), ("POTASSIUM", 99999))):
        v = int(top * ease_out(seg(lt, 0.1 + i * 0.15, 0.7 + i * 0.15)))
        text(img, (30, 44 + i * 30), name, 13, (255, 230, 170))
        text(img, (218, 44 + i * 30), f"+{v}", 13, (140, 255, 150), anchor="ra")
    box(img, 248, 30, 464, 170, top=(70, 10, 20), bottom=(30, 4, 10), inner=(255, 90, 100))
    for i, (at, s) in enumerate(((0.4, "UNKNOWN STARCHITECTURE"), (0.8, "TOO MANY POTATOES"), (1.2, "COMMUNITY CONTRIBUTIONS"))):
        if lt > at and (int(lt * 6) % 2 == 0 or lt > at + 0.4):
            text(img, (260, 46 + i * 36), "! " + s, 12, (255, 200, 200))
    tot(img, 120, 262, k=3, glow_eyes=True, arms="up")
    dot(img, 360, 232, 22)
    return img


for i in range(12):
    cue(s_stats, 0.1 + i * 0.07, "tick")
for at in (0.4, 0.8, 1.2):
    cue(s_stats, at, "alarm")


@shot(3.0)
def s_forking(img, lt):
    img = battlefield().copy()
    dot_field(img, 24 + lt, big=False)
    speaking = 0.9 < lt < 2.2
    dot(img, 300, 118 + 2 * math.sin(lt * 3), 13, glow=speaking, eye_on=not speaking or int(lt * 10) % 2 == 0)
    cdo(img, 390, 214, k=3, mouth="open" if (lt < 0.9 or lt > 2.2) and int(lt * 7) % 2 else "flat")
    return img


say(s_forking, 0.0, 0.9, "cdo", "What are they doing?")
say(s_forking, 0.95, 1.45, "dot", "Sir...")
say(s_forking, 1.5, 2.2, "dot", "They're forking.")
say(s_forking, 2.25, 3.0, "cdo", "...dear god.")

# ----------------------------------------------------------------------------------------------- the abilities

def ability(img, name, lt):
    banner(img, "TOT ABILITY: " + name, lt, y=50, col=(255, 190, 60), size=15)


DOTS_HP = [1.0]

FORK_SPOTS = [(x, y) for y in range(206, 270, 13) for x in range(14 + (y // 13 % 2) * 9, W, 18)]
RND.shuffle(FORK_SPOTS)


@shot(1.5)
def s_fork(img, lt):
    img = battlefield().copy()
    dot_field(img, 26 + lt)
    hp_bar(img, 16, 26, 180, lerp(1.0, 0.62, ease_out(seg(lt, 0.6, 1.0))), "DOT SENTRIES")
    for i, (x, y) in enumerate(FORK_SPOTS[:130]):
        if lt > 0.2 + i * 0.006:
            tot(img, x, y, k=1, glow=False, bob=1 if (i + int(lt * 8)) % 5 == 0 else 0)
    tot(img, 240, 206, k=3, hat=True, arms="up", glow_eyes=True)
    ability(img, "FORK()", lt)
    if lt > 0.7:
        s = seg(lt, 0.7, 1.3)
        text(img, (300, 80 - 20 * s), "-380", 14, (255, 240, 120), stroke=2, stroke_fill=(160, 20, 20), alpha=1 - s * 0.5)
    return img


cue(s_fork, 0.0, "powerup", short=True)
for i in range(10):
    cue(s_fork, 0.2 + i * 0.08, "pop")
cue(s_fork, 0.7, "boom", size=0.5)
shake(s_fork, 0.7, 3, 0.25)


def power(img, name, lt):
    banner(img, "TATER-TOT POWER: " + name, lt, y=50, col=(255, 170, 40), size=15)


@shot(1.7)
def s_grated(img, lt):
    """The tot shreds itself into minds - as many as the job needs, up to its size - one task each."""
    img = battlefield().copy()
    dot_field(img, 28 + lt)
    n = 8
    spread = ease_out(seg(lt, 0.3, 0.8))
    if lt < 0.3:
        tot(img, 240, 214, k=4, glow_eyes=True, arms="up")
    else:
        for i in range(n):
            ang = math.pi * (0.1 + 0.8 * i / (n - 1))
            x = 240 - math.cos(ang) * 180 * spread
            y = 214 - math.sin(ang) * 70 * spread
            tot(img, x, y, k=2, glow_eyes=True, hat=(i == 3), bob=1 if math.sin(lt * 9 + i) > 0.5 else 0)
        rnd = random.Random(2)
        for j in range(30):
            u = seg(lt, 0.3, 0.7)
            if 0 < u < 1:
                ang = rnd.random() * math.tau
                ImageDraw.Draw(img).rectangle((240 + math.cos(ang) * 60 * u, 190 + math.sin(ang) * 40 * u, 241 + math.cos(ang) * 60 * u, 191 + math.sin(ang) * 40 * u), fill=(240, 196, 112))
    if lt > 0.85:
        text(img, (W // 2, 230), "MINDS: 1 -> 8   one task each", 14, (255, 230, 150), anchor="mm", stroke=2)
        text(img, (W // 2, 248), "parallel processing, but make it potato", 11, (255, 255, 255), anchor="mm", stroke=2)
    power(img, "GRATED SWARM", lt)
    return img


cue(s_grated, 0.3, "grow")
for i in range(8):
    cue(s_grated, 0.32 + i * 0.05, "pop")


@shot(1.5)
def s_pad(img, lt):
    img = battlefield().copy()
    dot_field(img, 30 + lt)
    xs = (110, 175, 240, 305, 370)
    for i, x in enumerate(xs):
        tot(img, x, 214, k=2, hat=(i == 0), eyes="side", arms="up" if abs(lerp(110, 370, seg(lt, 0.1, 0.8)) - x) < 30 else "down")
    if lt < 0.85:
        u = seg(lt, 0.1, 0.8)
        nx = lerp(110, 370, u)
        ny = 160 - 30 * math.sin(u * math.pi * 4) ** 2
        ImageDraw.Draw(img).rectangle((nx - 6, ny - 6, nx + 6, ny + 6), fill=(255, 236, 110), outline=(200, 170, 40))
    else:
        s = ease_out(seg(lt, 0.85, 1.05))
        w2, h2 = int(150 * s), int(60 * s)
        d = ImageDraw.Draw(img)
        d.rectangle((240 - w2, 120 - h2, 240 + w2, 120 + h2), fill=(255, 236, 110), outline=(200, 170, 40))
        if s > 0.95:
            text(img, (240, 106), "the big one is", 15, (60, 50, 20), anchor="mm", stroke=0)
            text(img, (240, 126), "weak to forks", 15, (60, 50, 20), anchor="mm", stroke=0)
            text(img, (330, 160), "- gary", 12, (90, 70, 30), anchor="ra", stroke=0)
    ability(img, "SCRATCHPAD", lt)
    return img


cue(s_pad, 0.1, "paper")
cue(s_pad, 0.85, "paper")


@shot(1.5)
def s_armor(img, lt):
    """A hit that changes nothing: the fried shell takes it."""
    img = battlefield().copy()
    dot_field(img, 31 + lt)
    shell = 0.25 < lt < 0.9
    if shell:
        put(img, glow_img(64, (255, 190, 60), 0.75), 240, 168, anchor="center")
    tot(img, 240, 214, k=4, eyes="closed" if shell else "normal", mouth="flat" if shell else "smile", arms="up" if shell else "down")
    if 0.2 < lt < 0.4:
        d = ImageDraw.Draw(img)
        d.line((240, 80, 240, 130), fill=(255, 80, 90), width=5)
        d.line((240, 80, 240, 130), fill=(255, 230, 230), width=2)
    for i in range(6):
        sparkle(img, 200 + i * 16, 128 + (i % 2) * 22, lt - 0.3 - i * 0.04, (255, 230, 140))
    if lt > 0.45:
        s_ = bounce(seg(lt, 0.45, 0.7))
        text(img, (W // 2, 112), "0 DAMAGE", f=big(int(30 * s_)), fill=(255, 230, 120), anchor="mm", stroke=3, stroke_fill=(140, 70, 0))
    if lt > 0.75:
        text(img, (W // 2, 238), "a failed step changes nothing: SAME", 12, (255, 255, 255), anchor="mm", stroke=2)
    power(img, "CRISPY ARMOR", lt)
    return img


cue(s_armor, 0.2, "laser")
cue(s_armor, 0.3, "crunch")
cue(s_armor, 0.45, "stamp")


@shot(1.5)
def s_pr(img, lt):
    img = battlefield().copy()
    dot_field(img, 32 + lt)
    hp_bar(img, 16, 26, 180, lerp(0.62, 0.35, ease_out(seg(lt, 0.4, 0.8))), "DOT SENTRIES")
    ground_tots(img, lt, eyes="up", glow_eyes=True)
    y = lerp(-120, 96, ease_in(seg(lt, 0.05, 0.35)))
    put(img, glow_img(110, (120, 255, 160), 0.35), 240, y + 30, anchor="center")
    box(img, 110, int(y), 370, int(y) + 70, top=(236, 255, 240), bottom=(200, 236, 210), border=(40, 120, 60), inner=(120, 220, 150))
    text(img, (122, int(y) + 8), "PULL REQUEST #1337: tots > dots", 12, (30, 60, 40), stroke=0)
    text(img, (122, int(y) + 28), "+4,218 additions", 13, (20, 150, 60), stroke=0)
    text(img, (122, int(y) + 46), "-12 proprietary abstractions", 13, (200, 40, 50), stroke=0)
    if lt > 0.45:
        s = bounce(seg(lt, 0.45, 0.7))
        text(img, (W // 2, 186), "CRITICAL HIT!", f=big(int(36 * s)), fill=(255, 240, 80), anchor="mm", stroke=3, stroke_fill=(200, 30, 30))
    ability(img, "PULL REQUEST", lt)
    return img


cue(s_pr, 0.05, "whoosh")
cue(s_pr, 0.35, "boom", size=0.9)
cue(s_pr, 0.45, "crit")
shake(s_pr, 0.35, 6, 0.4)


@shot(2.1)
def s_deepfry(img, lt):
    """Into the fryer with a failure, out golden with a lesson."""
    img = battlefield().copy()
    dot_field(img, 34 + lt)
    d = ImageDraw.Draw(img)
    # the fryer
    d.rectangle((180, 168, 300, 214), fill=(70, 72, 84), outline=(30, 30, 36))
    d.rectangle((174, 164, 306, 170), fill=(110, 112, 126))
    rnd = random.Random(int(lt * 20))
    for i in range(14):
        bx = 186 + rnd.randrange(108)
        br = rnd.randrange(2, 5)
        d.ellipse((bx - br, 166 - br, bx + br, 166 + br), fill=(255, 210, 90) if 0.35 < lt < 1.2 else (200, 160, 70))
    if lt < 0.35:
        u = lt / 0.35
        tot(img, lerp(120, 240, u), 214 - math.sin(u * math.pi) * 70 - 40 * u, k=3, arms="up", mouth="open")
    elif lt > 1.1:
        u = seg(lt, 1.1, 1.35)
        y = lerp(170, 150, ease_out(u))
        put(img, glow_img(70, (255, 200, 80), 0.7), 240, y - 50, anchor="center")
        tot(img, 240, y, k=5, glow_eyes=True, arms="up", hat=False)
        text(img, (W // 2, 84), "LV UP!", f=big(30), fill=(255, 236, 120), anchor="mm", stroke=3, stroke_fill=(150, 60, 0))
    if lt > 1.35:
        box(img, 60, 216, 420, 246, top=(30, 70, 46), bottom=(22, 54, 36), border=(150, 110, 60), inner=(110, 80, 40))
        line = "+1 LESSON: don't punch chrome. fork it."
        text(img, (240, 231), line[: int((lt - 1.35) * 50)], 13, (240, 240, 230), anchor="mm", stroke=0)
    power(img, "DEEP FRY LEARNING", lt)
    return img


cue(s_deepfry, 0.0, "whoosh")
cue(s_deepfry, 0.35, "sizzle")
cue(s_deepfry, 1.1, "powerup")
cue(s_deepfry, 1.15, "achievement")


BUTTONS = ["[1] pricing", "[2] roadmap", "[3] upsell", "[4] watch", "[5] more dots", "[6] enterprise", "[7] power off", "[8] terms", "[9] contact sales"]


def cursor(img, x, y):
    d = ImageDraw.Draw(img)
    d.polygon(((x, y), (x, y + 12), (x + 3, y + 9), (x + 6, y + 14), (x + 8, y + 13), (x + 5, y + 8), (x + 9, y + 8)), fill=(255, 255, 255), outline=(0, 0, 0))


@shot(2.9)
def s_browser(img, lt):
    img = battlefield().copy()
    dot(img, 420, 70 + 2 * math.sin(lt * 3), 20, glow=lt < 0.75, eye_on=lt < 0.75)
    shrink = ease_in(seg(lt, 2.4, 2.65))
    if shrink < 1:
        x0, y0, x1, y1 = 20, 30, 360 - int(250 * shrink), 200 - int(150 * shrink)
        d = ImageDraw.Draw(img)
        d.rectangle((x0, y0, x1, y1), fill=(236, 238, 244), outline=(80, 80, 100))
        d.rectangle((x0, y0, x1, y0 + 14), fill=(200, 204, 216))
        if shrink == 0:
            text(img, (x0 + 6, y0 + 2), "dots-control-panel" if lt < 1.3 else "verify you are human", 10, (40, 40, 60), stroke=0)
            if lt < 1.3:
                for i, b in enumerate(BUTTONS):
                    bx, by = x0 + 10 + (i % 3) * 110, y0 + 26 + (i // 3) * 46
                    hot = i == 6 and lt > 0.7
                    d.rectangle((bx, by, bx + 100, by + 34), fill=(255, 220, 220) if hot else (255, 255, 255), outline=(150, 150, 170))
                    text(img, (bx + 50, by + 17), b, 11, (40, 40, 70), anchor="mm", stroke=0)
                cx = lerp(300, x0 + 10 + 110 + 60, ease_io(seg(lt, 0.2, 0.7)))
                cy = lerp(180, y0 + 26 + 92 + 20, ease_io(seg(lt, 0.2, 0.7)))
                cursor(img, cx, cy)
            else:
                d.rectangle((x0 + 40, y0 + 30, x1 - 40, y0 + 150), fill=(255, 255, 255), outline=(160, 160, 180))
                text(img, (x0 + 170, y0 + 44), "BOT CHECK", 15, (200, 40, 60), anchor="mm", stroke=0)
                for i in range(9):
                    gx, gy = x0 + 110 + (i % 3) * 40, y0 + 62 + (i // 3) * 28
                    d.rectangle((gx, gy, gx + 34, gy + 24), fill=(180, 186, 200), outline=(120, 120, 140))
                    put(img, dot_img(6, eye=False), gx + 17, gy + 12, anchor="center")
    tot(img, 420, 214, k=3, eyes="left", mouth="flat" if lt > 1.3 else "smile")
    return img


say(s_browser, 0.05, 0.75, "tot", "click [7].")
say(s_browser, 1.55, 2.4, "tot", "one more step.")
cue(s_browser, 0.75, "click")
cue(s_browser, 0.8, "powerdown")
cue(s_browser, 1.3, "alarm")
cue(s_browser, 2.4, "whoosh")


@shot(3.2)
def s_account(img, lt):
    img = dark((18, 22, 40))
    d = ImageDraw.Draw(img)
    # the dots' servers: empty
    d.rectangle((24, 96, 92, 174), fill=(60, 64, 80), outline=(140, 140, 160))
    for i in range(4):
        d.rectangle((32, 104 + i * 17, 84, 115 + i * 17), fill=(40, 44, 56))
        d.point((78, 109 + i * 17), fill=(255, 60, 70) if int(lt * 4 + i) % 2 else (90, 30, 30))
    text(img, (58, 178), "DOT SERVERS", 11, (200, 200, 220), anchor="ma")
    text(img, (58, 192), "(no tater-tots here)", 10, (150, 150, 170), anchor="ma")
    # the user's own account: the tots, working
    for cx, cy, r in ((200, 140, 38), (250, 124, 46), (305, 140, 40), (250, 158, 46)):
        d.ellipse((cx - r, cy - r * 0.8, cx + r, cy + r * 0.8), fill=(220, 236, 255))
    text(img, (252, 90), "YOUR CLOUDFLARE ACCOUNT", 12, (255, 255, 255), anchor="mm")
    for i, x in enumerate((210, 252, 294)):
        tot(img, x, 176, k=2, glow_eyes=True, hat=(i == 1), bob=1 if math.sin(lt * 8 + i) > 0 else 0)
    # the laptop: closed
    d.polygon(((370, 160), (450, 160), (460, 170), (360, 170)), fill=(170, 176, 190), outline=(90, 90, 110))
    d.rectangle((372, 154, 448, 160), fill=(130, 136, 150))
    text(img, (410, 178), "your laptop: closed", 11, (200, 200, 220), anchor="ma")
    text(img, (430, 134 - 6 * math.sin(lt * 3)), "z z z", 12, (180, 200, 255), anchor="mm", stroke=0)
    ability(img, "YOUR OWN ACCOUNT", lt)
    return img


say(s_account, 0.3, 1.3, "dot", "Sir... they're not on our servers.")
say(s_account, 1.35, 2.4, "dot", "And their human's laptop is closed.")
say(s_account, 2.45, 3.2, "tot", "skill issue.")

# =================================================================================================== 5. FINAL BATTLE

CONVERGE = [(RND.randrange(-60, W + 60), RND.choice((-40, RND.randrange(0, 200))), RND.randrange(5, 11)) for _ in range(34)]


def dot_prime(img, t, hp=1.0, cracked=False, shake_=0):
    put(img, glow_img(90, (255, 60, 80), 0.4), 240, 100, anchor="center")
    dot(img, 240 + shake_, 100 + 3 * math.sin(t * 2), 58, cracked=cracked, t=t)
    hp_bar(img, 20, 24, 440, hp, "DOT PRIME", col=(255, 70, 90))


@shot(3.4)
def s_prime(img, lt):
    img = anime_sky(lt)
    if lt < 1.0:
        for x, y, r in CONVERGE:
            u = ease_in(seg(lt, 0, 1.0))
            dot(img, lerp(x, 240, u), lerp(y, 100, u), r, t=lt)
    else:
        dot_prime(img, lt, hp=ease_out(seg(lt, 1.0, 1.4)))
    if 1.0 <= lt < 1.15:
        flash(img, 1 - seg(lt, 1.0, 1.15))
    cdo(img, 420, 214, k=2, arm="raise")
    tot(img, 120, 214, k=2, hat=True, eyes="up", mouth="o")
    return img


cue(s_prime, 0.0, "rumble")
cue(s_prime, 1.0, "boom", size=1.0)
shake(s_prime, 1.0, 6, 0.5)
say(s_prime, 1.5, 2.4, "cdo", "You are... TATER-TOTS.")
say(s_prime, 2.45, 3.4, "cdo", "YOU CANNOT POSSIBLY COMPETE WITH US.")


@shot(3.5)
def s_alone(img, lt):
    img = anime_sky(lt + 4)
    tint(img, (0, 0, 0), 0.3)
    dot_prime(img, lt + 4)
    if lt > 2.0:
        a = seg(lt, 2.0, 2.4)
        for i in range(40):
            x = 20 + (i * 37) % 440
            y = 200 - (i % 3) * 6
            tot(img, x, y, k=1, glow=False, glow_eyes=True) if a > (i / 40) else None
    if lt > 1.6:
        for x in (150, 330):
            xx = lerp(-30 if x < 240 else W + 30, x, ease_out(seg(lt, 1.6, 2.0)))
            tot(img, xx, 222, k=3, walk_t=lt if lt < 2.0 else None, glow_eyes=lt > 2.0)
    tot(img, 240, 226, k=5, hat=True, leaf=lt > 0.4, glow_eyes=lt > 2.3, mouth="flat" if lt < 0.9 else "smile")
    sparkle(img, 250, 150, lt - 0.4, (150, 255, 150))
    if lt > 0.6:
        box(img, 300, 40, 470, 64, top=(20, 20, 40), bottom=(10, 10, 20), inner=(140, 140, 200))
        mood = "wary" if lt < 1.0 else "encouraged"
        text(img, (308, 46), "MOOD: " + mood, 12, (255, 160, 160) if lt < 1.0 else (150, 255, 170))
    d = ImageDraw.Draw(img)
    for i in range(6):
        y = 60 + i * 30
        x = (W - ((lt * 500 + i * 120) % (W + 80)))
        d.line((x, y, x + 24, y), fill=(200, 190, 230))
    return img


cue(s_alone, 0.0, "wind")
cue(s_alone, 0.4, "sparkle")
say(s_alone, 0.9, 1.6, "gary", "maybe.")
say(s_alone, 2.3, 3.5, "gary", "but we're open source.")
for i in range(3):
    cue(s_alone, 1.6 + i * 0.12, "pip", n=40 + i)


@shot(3.6)
def s_ascend(img, lt):
    img = anime_sky(lt + 8)
    tint(img, (255, 170, 40), 0.18 + 0.1 * math.sin(lt * 10))
    d = ImageDraw.Draw(img)
    rise = ease_io(seg(lt, 0.2, 2.2)) * 70
    for i, x in enumerate((140, 240, 340)):
        beam = Image.new("RGBA", (40, H), (255, 220, 120, 70))
        img.paste(beam, (x - 20, 0), beam)
        tot(img, x, 226 - rise - (10 if x == 240 else 0), k=4 if x == 240 else 3, hat=(x == 240), leaf=(x == 240), glow_eyes=True, arms="up")
    rnd = random.Random(9)
    for i in range(60):
        x = rnd.randrange(W)
        y = (rnd.randrange(H) - lt * (60 + rnd.randrange(80))) % H
        d.point((x, y), fill=(255, 236, 150))
    for at, word, x in ((0.4, "THINK", 110), (0.9, "FEEL", 240), (1.4, "REASON", 370)):
        if lt > at:
            s = bounce(seg(lt, at, at + 0.25))
            text(img, (x, 40), word, f=big(int(28 * s)), fill=(255, 255, 255), anchor="mm", stroke=3, stroke_fill=(180, 100, 0))
    if lt > 2.0:
        s = bounce(seg(lt, 2.0, 2.3))
        text(img, (W // 2, 90), "TATER-TOTS ASCEND", f=big(int(40 * s)), fill=(255, 220, 90), anchor="mm", stroke=4, stroke_fill=(110, 40, 0))
    if lt > 2.6:
        text(img, (W // 2, 124), "STRENGTH: NEVER BEFORE SEEN", 14, (255, 250, 220), anchor="mm", stroke=2, stroke_fill=(110, 40, 0))
    return img


cue(s_ascend, 0.0, "choir")
cue(s_ascend, 0.1, "powerup")
for at in (0.4, 0.9, 1.4):
    cue(s_ascend, at, "stamp")
cue(s_ascend, 2.0, "boom", size=0.6)
shake(s_ascend, 2.0, 3, 0.3)

@shot(2.2)
def s_hasta(img, lt):
    img = anime_sky(lt + 10)
    tint(img, (0, 0, 0), 0.35)
    dot_prime(img, lt + 10, hp=0.35)
    on = lt > 0.35
    tot(img, 240, 262, k=6, hat=True, leaf=True, shades=on, mouth="flat" if on else "smile", glow=True)
    if lt < 0.35:
        y = lerp(-20, 188, lt / 0.35)
        ImageDraw.Draw(img).rectangle((208, y, 272, y + 5), fill=(10, 10, 14))
    return img


say(s_hasta, 0.5, 2.2, "gary", "hasta la vista, dots.")
cue(s_hasta, 0.35, "stamp")


CODE = "fork() pr merge feel() think() reason() 0x7a7 01101 git push tots>dots"


@shot(3.6)
def s_ult(img, lt):
    img = anime_sky(lt + 12)
    dot_prime(img, lt + 12, hp=0.35)
    rnd = random.Random(4)
    for i in range(26):
        x = rnd.randrange(W)
        sp = 80 + rnd.randrange(120)
        for j in range(6):
            y = (rnd.randrange(H) + lt * sp + j * 10) % H
            text(img, (x, y), CODE[(i * 7 + j) % len(CODE)], f=mono(10), fill=(90, 255, 140), stroke=0)
    d = ImageDraw.Draw(img)
    for i, col in enumerate(((255, 120, 80), (120, 200, 255), (200, 120, 255))):
        pts = [(x, 170 + i * 12 + 8 * math.sin(x / 40 + lt * 3 + i)) for x in range(0, W, 10)]
        d.line(pts, fill=col, width=2)
        for x in range(30 + i * 40, W, 120):
            y = 170 + i * 12 + 8 * math.sin(x / 40 + lt * 3 + i)
            d.ellipse((x - 3, y - 3, x + 3, y + 3), fill=col, outline=(255, 255, 255))
    dive = seg(lt, 3.0, 3.5)
    for i in range(12):
        ang = lt * 3 + i * math.tau / 12
        r = lerp(130, 0, ease_in(dive))
        x = 240 + r * math.cos(ang)
        y = lerp(200, 100, ease_in(dive)) + r * 0.35 * math.sin(ang)
        tot(img, x, y + 20, k=2, glow_eyes=True, arms="up", angle=int(lt * 400 + i * 30) % 360 if dive > 0 else 0, hat=(i == 0))
    if lt > 0.3:
        s = bounce(seg(lt, 0.3, 0.6))
        text(img, (W // 2, 158), "OPEN SOURCE POTATO SWARM", f=big(int(30 * s)), fill=(255, 220, 90), anchor="mm", stroke=3, stroke_fill=(120, 40, 0))
    for i, (at, s) in enumerate(((1.2, "SYSTEM ERROR"), (1.5, "TOO MANY TOTS"), (1.8, "TOO WARM"), (2.1, "TOO FORKABLE"))):
        if lt > at and int(lt * 8) % 4 != 0:
            text(img, (470, 50 + i * 16), s, 12, (255, 90, 100), anchor="ra", stroke=2)
    return img


cue(s_ult, 0.3, "boom", size=0.5)
for at in (1.2, 1.5, 1.8, 2.1):
    cue(s_ult, at, "alarm")
say(s_ult, 2.4, 3.1, "cdo", "WAIT WAIT WAIT--")
cue(s_ult, 3.0, "whoosh")


@shot(1.5)
def s_boom(img, lt):
    img = anime_sky(16)
    dot_prime(img, 16, hp=0.35, cracked=True, shake_=int(6 * math.sin(lt * 60)))
    explosion(img, 240, 110, lt * 0.8, 180, seed=99)
    explosion(img, 160, 140, lt * 0.8 - 0.1, 90, seed=7)
    explosion(img, 330, 90, lt * 0.8 - 0.15, 90, seed=8)
    flash(img, 1 - seg(lt, 0, 0.45))
    return img


cue(s_boom, 0.0, "boom", size=1.6)
cue(s_boom, 0.15, "boom", size=1.0)
shake(s_boom, 0.0, 10, 1.0)


@shot(2.2)
def s_damage(img, lt):
    img = anime_sky(18)
    tint(img, (0, 0, 0), 0.25)
    dot_prime(img, 18, hp=lerp(0.35, 0.0, ease_io(seg(lt, 0.3, 1.2))), cracked=True, shake_=int(3 * math.sin(lt * 50)) if lt < 1.2 else 0)
    for i, (at, x, y) in enumerate(((0.0, 150, 80), (0.25, 320, 60), (0.5, 240, 150))):
        if lt > at:
            u = seg(lt, at, at + 0.5)
            s = bounce(seg(lt, at, at + 0.2))
            text(img, (x, y - 14 * u), "999999", f=big(int(30 * s)), fill=(255, 250, 120), anchor="mm", stroke=3, stroke_fill=(200, 20, 30))
    if lt > 0.8:
        s = bounce(seg(lt, 0.8, 1.05))
        text(img, (W // 2, 200), "SUPER EFFECTIVE!", f=big(int(34 * s)), fill=(140, 255, 160), anchor="mm", stroke=3, stroke_fill=(0, 80, 30))
    if lt > 1.2:
        box(img, 150, 240, 470, 264, top=(10, 40, 20), bottom=(4, 20, 10), inner=(120, 230, 150))
        text(img, (158, 246), "ITERATION 47: IMPROVED - evidence: DOT PRIME HP 0", 10, (170, 255, 190))
    return img


for at in (0.0, 0.25, 0.5):
    cue(s_damage, at, "hit")
cue(s_damage, 0.8, "achievement")


def crater_scene(img, lt, holding=False):
    d = ImageDraw.Draw(img)
    d.ellipse((250, 190, 470, 236), fill=(30, 22, 30))
    cdo(img, 360, 236, k=3, messy=True, holding=holding, mouth="flat")
    d.chord((250, 200, 470, 250), 0, 180, fill=(58, 44, 58))  # the crater's front rim hides his legs
    d.arc((250, 190, 470, 236), 180, 360, fill=(90, 70, 90))
    for i in range(5):
        x = (80 + i * 90 + lt * 12) % W
        y = 150 - (lt * 8 + i * 13) % 60
        r = 14 + i % 3 * 5
        d.ellipse((x - r, y - r * 0.7, x + r, y + r * 0.7), fill=(110, 100, 112))


@shot(8.0)
def s_after(img, lt):
    img = battlefield().copy()
    tint(img, (40, 30, 40), 0.35)
    crater_scene(img, lt, holding=lt > 5.9)
    if lt < 1.8:
        x = lerp(-20, 250, seg(lt, 0.4, 1.6))
        put(img, dot_img(8, eye_on=False, cracked=True).rotate(-lt * 300, resample=Image.NEAREST), x, 222, anchor="center")
    gx = lerp(-30, 190, ease_out(seg(lt, 1.0, 2.0)))
    tot(img, gx, 236, k=3, hat=True, leaf=True, walk_t=lt if lt < 2.0 else None, arms="offer" if 2.0 < lt < 5.9 else "down")
    if lt > 4.7:
        tot(img, lerp(-20, 130, ease_out(seg(lt, 4.7, 4.9))), 236, k=3)
    if lt > 5.3:
        tot(img, lerp(-20, 80, ease_out(seg(lt, 5.3, 5.5))), 236, k=3)
    if lt > 6.0:
        tot(img, 40, 200, k=1, glow_eyes=True)
        box(img, 110, 10, 370, 46, top=(20, 60, 30), bottom=(10, 36, 18), inner=(140, 240, 160))
        text(img, (240, 20), "HUMANITY: SAVED", 13, (180, 255, 190), anchor="mm")
        text(img, (240, 36), "your backlog: also caught up", 10, (230, 255, 230), anchor="mm")
    return img


for i in range(4):
    cue(s_after, 0.5 + i * 0.32, "clink")
cue(s_after, 0.0, "wind")
say(s_after, 2.0, 2.8, "cdo", "...what is this?")
say(s_after, 2.85, 3.4, "gary", "a tater-tot.")
say(s_after, 3.45, 3.9, "cdo", "...")
say(s_after, 3.95, 4.7, "gary", "it's open source.")
say(s_after, 4.75, 5.3, "tot", "and warm.")
say(s_after, 5.35, 5.9, "tot", "very warm.")
cue(s_after, 5.9, "sigh")
say(s_after, 6.1, 8.0, "tot (far away)", "goal achieved. moving on to the next best thing.")

# =================================================================================================== 6. PRODUCT REVEAL (full resolution)

import reveal  # noqa: E402

s_meet = shot(1.9, hires=True)(reveal.meet)
s_beats = shot(reveal.BEAT * len(reveal.BEATS), hires=True)(reveal.beats)
s_triple = shot(2.0, hires=True)(reveal.triple)
s_final = shot(3.6, hires=True)(reveal.final)
s_black = shot(1.0, hires=True)(reveal.black)

for i in range(len(reveal.BEATS)):
    cue(s_beats, i * reveal.BEAT, "tick", soft=True)
for i in range(3):
    cue(s_triple, i * 0.45, "stamp", soft=True)
cue(s_final, 1.9, "pop")
cue(s_black, 0.1, "pop")

# ----------------------------------------------------------------------------------------------- music map

MUSIC += [
    (s_trailer.t0, s_enter.t0, "trailer"),
    (s_enter.t0, s_desktop.t0, "wholesome"),
    (s_desktop.t0, s_warn.t0, "drone"),
    (s_apocalypse.t0, s_apocalypse.t0 + 2.9, "boss"),
    (s_descend.t0, s_freeze.t0, "boss"),
    (s_freeze.t0 + 1.8, s_awaken.t0, "villain"),
    (s_terminal.t0, s_fork.t0, "build"),
    (s_fork.t0, s_alone.t0, "battle"),
    (s_alone.t0, s_ascend.t0, "drone"),
    (s_ascend.t0, s_boom.t0 + 0.05, "finale"),
    (s_meet.t0, s_black.t0, "clean"),
]

TOTAL = CUR[0]
