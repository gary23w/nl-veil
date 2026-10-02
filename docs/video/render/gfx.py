"""Pixel-art building blocks for the tots release video: sprites, backgrounds, text, effects.

Everything is drawn on a 480x270 canvas (RGBA) and scaled 4x with nearest-neighbour at the end, so every shape
is made of real pixels. Sprites are drawn once at their base size and cached; a bigger sprite is the base one
scaled up by a whole number, so pixels stay square at every size.
"""
import math
import random
from functools import lru_cache

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 480, 270
FONTS = "C:/Windows/Fonts/"

# ----------------------------------------------------------------------------------------------- small maths

def clamp01(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x

def seg(t, a, b):
    """0 before a, 1 after b, linear between."""
    return clamp01((t - a) / (b - a)) if b > a else (1.0 if t >= a else 0.0)

def ease_out(x):
    return 1 - (1 - clamp01(x)) ** 3

def ease_in(x):
    return clamp01(x) ** 3

def ease_io(x):
    x = clamp01(x)
    return 4 * x * x * x if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2

def lerp(a, b, x):
    return a + (b - a) * x

def mix(c1, c2, x):
    return tuple(int(round(lerp(a, b, clamp01(x)))) for a, b in zip(c1, c2))

def bounce(x):
    """An overshoot that settles: 0 -> 1.15 -> 1."""
    x = clamp01(x)
    return 1 + 0.15 * math.sin(x * math.pi) * (1 - x) * 2 if x < 1 else 1.0

# ----------------------------------------------------------------------------------------------- text

@lru_cache(maxsize=None)
def font(name, size):
    return ImageFont.truetype(FONTS + name, size)

def pix(size=10):
    return font("tahomabd.ttf", size)

def mono(size=10):
    return font("consolab.ttf", size)

def big(size=40):
    return font("impact.ttf", size)

def draw(img):
    d = ImageDraw.Draw(img)
    d.fontmode = "1"  # no anti-aliasing: pixel text
    return d

def text(img, xy, s, size=10, fill=(255, 255, 255), anchor="la", f=None, stroke=1, stroke_fill=(0, 0, 0), alpha=1.0):
    f = f or pix(size)
    if alpha >= 0.999:
        draw(img).text(xy, s, font=f, fill=fill, anchor=anchor, stroke_width=stroke, stroke_fill=stroke_fill)
        return
    if alpha <= 0.001:
        return
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw(layer).text(xy, s, font=f, fill=fill + (255,), anchor=anchor, stroke_width=stroke, stroke_fill=stroke_fill + (255,))
    a = layer.getchannel("A").point(lambda v: int(v * alpha))
    layer.putalpha(a)
    img.alpha_composite(layer)

def wrap(s, f, width):
    words, lines, cur = s.split(" "), [], ""
    for w_ in words:
        cand = (cur + " " + w_).strip()
        if f.getlength(cand) <= width or not cur:
            cur = cand
        else:
            lines.append(cur)
            cur = w_
    if cur:
        lines.append(cur)
    return lines

# ----------------------------------------------------------------------------------------------- palette

BODY = (218, 150, 58)
SHADE = (180, 112, 36)
HL = (242, 196, 112)
OUT = (104, 58, 20)
SPOT = (150, 88, 30)
BLUSH = (246, 150, 150)
EYE = (24, 18, 22)
HAT = (246, 200, 52)
HAT_D = (196, 150, 30)
LEAF = (88, 186, 72)
LEAF_D = (52, 130, 48)

# ----------------------------------------------------------------------------------------------- the tot

@lru_cache(maxsize=None)
def tot_base(step=0, eyes="normal", mouth="smile", arms="down", hat=False, leaf=False, glow_eyes=False, shades=False):
    """A tot - a tater tot, a little crispy cylinder of grated potato - at its base size, 22x26, feet on the
    bottom row."""
    im = Image.new("RGBA", (22, 26), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lf = 1 if step == 1 else 0
    rf = 1 if step == 2 else 0
    d.ellipse((5, 22 - lf, 9, 25 - lf), fill=OUT)
    d.ellipse((12, 22 - rf, 16, 25 - rf), fill=OUT)
    arm = OUT
    if arms == "down":
        d.line((4, 15, 1, 19), fill=arm)
        d.line((17, 15, 20, 19), fill=arm)
    elif arms == "wave":
        d.line((4, 15, 1, 19), fill=arm)
        d.line((17, 14, 21, 9), fill=arm)
    elif arms == "up":
        d.line((4, 14, 0, 9), fill=arm)
        d.line((17, 14, 21, 9), fill=arm)
    elif arms == "point":
        d.line((4, 15, 1, 19), fill=arm)
        d.line((17, 14, 21, 13), fill=arm)
    # the cylinder: a rounded column, darker crisp sides, a lighter top
    d.rounded_rectangle((4, 5, 17, 23), radius=4, fill=BODY, outline=OUT)
    d.rectangle((14, 8, 16, 21), fill=SHADE)
    d.line((5, 9, 5, 19), fill=SHADE)
    d.ellipse((5, 4, 16, 9), fill=HL, outline=OUT)
    d.ellipse((8, 5, 13, 7), fill=(250, 220, 160))
    # grated, fried texture
    for p in ((7, 11), (10, 18), (13, 11), (15, 18), (6, 21), (12, 21), (9, 10), (14, 15), (6, 16)):
        d.point(p, fill=SPOT)
    for p in ((8, 19), (13, 19), (11, 10), (6, 13)):
        d.point(p, fill=(236, 186, 110))
    ec = (255, 238, 120) if glow_eyes else EYE
    dy = {"up": -1, "down": 1}.get(eyes, 0)
    dx = {"side": 1, "left": -1}.get(eyes, 0)
    if eyes == "closed":
        d.line((7, 13, 8, 13), fill=EYE)
        d.line((12, 13, 13, 13), fill=EYE)
    else:
        for ex in (7, 12):
            d.rectangle((ex + dx, 12 + dy, ex + dx + 1, 13 + dy), fill=ec)
            if not glow_eyes:
                d.point((ex + dx, 12 + dy), fill=(255, 255, 255))
    for p in ((5, 15), (6, 15), (14, 15), (15, 15)):
        d.point(p, fill=BLUSH)
    if mouth == "smile":
        d.point((9, 15), fill=EYE)
        d.line((10, 16, 11, 16), fill=EYE)
        d.point((12, 15), fill=EYE)
    elif mouth == "open":
        d.rectangle((10, 15, 11, 16), fill=(120, 30, 40))
    elif mouth == "flat":
        d.line((10, 16, 11, 16), fill=EYE)
    elif mouth == "o":
        d.point((10, 16), fill=EYE)
    if arms == "offer":
        d.line((4, 16, 8, 19), fill=arm)
        d.line((17, 16, 13, 19), fill=arm)
        d.rounded_rectangle((8, 16, 13, 21), radius=1, fill=HL, outline=OUT)
    if shades:
        d.rectangle((5, 11, 16, 13), fill=(10, 10, 14))
        d.line((10, 11, 11, 11), fill=(10, 10, 14))
        d.point((7, 11), fill=(255, 255, 255))
        d.point((13, 11), fill=(255, 255, 255))
    if hat:
        d.chord((5, 0, 16, 9), 180, 360, fill=HAT, outline=HAT_D)
        d.line((4, 4, 17, 4), fill=HAT_D)
        d.point((10, 1), fill=(255, 240, 160))
    if leaf:
        top = 0 if hat else 3
        d.line((10, top, 10, top + 2), fill=LEAF_D)
        d.polygon(((10, top), (13, top - 2), (14, top), (11, top + 1)), fill=LEAF)
    return im

@lru_cache(maxsize=None)
def tot_img(k=2, flip=False, angle=0, **kw):
    im = tot_base(**kw)
    if k != 1:
        im = im.resize((im.width * k, im.height * k), Image.NEAREST)
    if flip:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if angle:
        im = im.rotate(angle, resample=Image.NEAREST, expand=True)
    return im

@lru_cache(maxsize=None)
def glow_img(r, color=(255, 200, 120), strength=0.55):
    s = 2 * r + 1
    yy, xx = np.mgrid[0:s, 0:s]
    d = np.sqrt((xx - r) ** 2 + (yy - r) ** 2) / r
    a = np.clip(1 - d, 0, 1) ** 2 * 255 * strength
    a = (np.round(a / 32) * 32).clip(0, 255)  # banded, like a 16-bit glow
    arr = np.zeros((s, s, 4), np.uint8)
    arr[..., 0], arr[..., 1], arr[..., 2] = color
    arr[..., 3] = a.astype(np.uint8)
    return Image.fromarray(arr, "RGBA")

def put(img, sprite, x, y, anchor="bottom"):
    """Paste a sprite with its bottom-centre (or centre) at x, y."""
    if anchor == "bottom":
        px, py = int(round(x - sprite.width / 2)), int(round(y - sprite.height))
    else:
        px, py = int(round(x - sprite.width / 2)), int(round(y - sprite.height / 2))
    if px > img.width or py > img.height or px + sprite.width < 0 or py + sprite.height < 0:
        return
    img.paste(sprite, (px, py), sprite)

def tot(img, x, y, k=2, glow=True, walk_t=None, bob=0, **kw):
    """A tot standing (or walking) with its feet at (x, y)."""
    if walk_t is not None:
        ph = int(walk_t * 8) % 4
        kw["step"] = (0, 1, 0, 2)[ph]
        bob = bob + (1 if ph in (1, 3) else 0)
    if glow:
        g = glow_img(int(14 * k))
        put(img, g, x, y - 12 * k, anchor="center")
    put(img, tot_img(k=k, **kw), x, y - bob * k)

# ----------------------------------------------------------------------------------------------- the dot

RING_COLS = ((196, 200, 222), (0, 176, 255), (255, 200, 40), (228, 96, 224), (180, 214, 20))


@lru_cache(maxsize=None)
def dot_img(r, eye=True, eye_on=True, cracked=False, col=0):
    """A dot: a glossy ring with a dark hole, and in the hole a red eye that watches."""
    s = 2 * r + 3
    c = r + 1
    yy, xx = np.mgrid[0:s, 0:s].astype(float)
    dx, dy = (xx - c) / r, (yy - c) / r
    d = np.sqrt(dx * dx + dy * dy)
    ri = 0.42
    ring = (d <= 1.0) & (d >= ri)
    # the tube's cross-section: light from the top left, a highlight along the inner top edge
    u = (d - ri) / (1 - ri) * 2 - 1  # -1 at the inner edge, 1 at the outer
    nz = np.sqrt(np.clip(1 - u * u, 0, 1))
    nx, ny = u * dx / np.maximum(d, 1e-6), u * dy / np.maximum(d, 1e-6)
    lam = np.clip(-0.5 * nx - 0.6 * ny + 0.62 * nz, 0, 1)
    v = np.round((0.35 + 0.65 * lam) * 5) / 5
    base = np.array(RING_COLS[col % len(RING_COLS)], float)
    rgb = base[None, None, :] * (0.45 + 0.55 * v[..., None]) + 255 * np.clip(v - 0.8, 0, 1)[..., None] * 1.5
    spec = ring & ((-0.5 * nx - 0.6 * ny + 0.62 * nz) > 0.97)
    rgb[spec] = [255, 255, 255]
    edge = ring & ((d > 1 - 1.6 / r) | (d < ri + 1.4 / r))
    rgb[edge] = base * 0.35
    arr = np.zeros((s, s, 4), np.uint8)
    arr[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    arr[..., 3] = np.where(ring, 255, 0)
    hole = d < ri
    arr[hole] = (20, 18, 28, 255)
    im = Image.fromarray(arr, "RGBA")
    dd = ImageDraw.Draw(im)
    if eye:
        er = max(1, int(r * 0.16))
        col_e = (255, 60, 70) if eye_on else (70, 30, 34)
        dd.ellipse((c - er, c - er, c + er, c + er), fill=col_e)
        if eye_on and er >= 2:
            dd.point((c - er // 2, c - er // 2), fill=(255, 210, 210))
    if cracked:
        pts = [(c - r * 0.9, c - r * 0.3), (c - r * 0.5, c - r * 0.1), (c - r * 0.6, c + r * 0.3), (c - r * 0.2, c + r * 0.7)]
        dd.line(pts, fill=(20, 20, 26), width=max(1, r // 20))
    return im

def thrusters(img, x, y, r, t):
    """A sentry's jets under it and an antenna on top, its tip blinking."""
    d = ImageDraw.Draw(img)
    for i, sx in enumerate((-0.45, 0.45)):
        fl = r * (0.45 + 0.25 * abs(math.sin(t * 23 + x * 0.7 + i * 2)))
        bx = x + r * sx
        d.polygon(((bx - r * 0.18, y + r * 0.85), (bx + r * 0.18, y + r * 0.85), (bx, y + r * 0.85 + fl)), fill=(255, 150, 40))
        d.polygon(((bx - r * 0.09, y + r * 0.85), (bx + r * 0.09, y + r * 0.85), (bx, y + r * 0.85 + fl * 0.6)), fill=(255, 240, 160))
        d.rectangle((bx - r * 0.2, y + r * 0.72, bx + r * 0.2, y + r * 0.9), fill=(70, 72, 86))
    d.line((x, y - r, x + r * 0.15, y - r * 1.4), fill=(90, 92, 106), width=max(1, r // 8))
    tip = (255, 60, 70) if int(t * 3 + x) % 2 else (120, 30, 34)
    d.ellipse((x + r * 0.15 - 1.5, y - r * 1.4 - 1.5, x + r * 0.15 + 1.5, y - r * 1.4 + 1.5), fill=tip)


def scan_cone(img, x, y, ang, length=150, spread=0.22, alpha=60):
    """A sentry's red searchlight."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    pts = [(x, y), (x + length * math.cos(ang - spread), y + length * math.sin(ang - spread)), (x + length * math.cos(ang + spread), y + length * math.sin(ang + spread))]
    ImageDraw.Draw(layer).polygon(pts, fill=(255, 40, 50, alpha))
    img.alpha_composite(layer)


def dot(img, x, y, r=10, glow=False, t=None, **kw):
    if glow:
        put(img, glow_img(int(r * 1.8), (255, 70, 80), 0.35), x, y, anchor="center")
    if t is not None and r >= 5:
        thrusters(img, x, y, r, t)
    put(img, dot_img(r, **kw), x, y, anchor="center")

# ----------------------------------------------------------------------------------------------- the Chief Dot Officer

CAPE = (112, 40, 168)
CAPE_D = (74, 22, 118)
GOLD = (236, 192, 64)
SUIT = (34, 34, 46)
SKIN = (238, 196, 160)
HAIR = (64, 62, 74)

@lru_cache(maxsize=None)
def cdo_base(arm="down", messy=False, silhouette=False, holding=False, mouth="smirk"):
    """A made-up 16-bit villain, 34x56: cape, suit, chrome visor."""
    im = Image.new("RGBA", (34, 56), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # cape
    d.polygon(((9, 16), (25, 16), (33, 55), (1, 55)), fill=CAPE, outline=CAPE_D)
    d.line((1, 55, 33, 55), fill=GOLD)
    d.line((9, 16, 1, 55), fill=GOLD)
    d.line((25, 16, 33, 55), fill=GOLD)
    # legs
    d.rectangle((12, 40, 15, 53), fill=SUIT)
    d.rectangle((18, 40, 21, 53), fill=SUIT)
    d.rectangle((11, 53, 16, 55), fill=(12, 12, 16))
    d.rectangle((17, 53, 22, 55), fill=(12, 12, 16))
    # body
    d.polygon(((10, 17), (24, 17), (23, 41), (11, 41)), fill=SUIT)
    d.polygon(((15, 17), (19, 17), (17, 26)), fill=(240, 240, 240))
    d.line((17, 19, 17, 27), fill=GOLD)
    d.rectangle((9, 15, 25, 18), fill=GOLD)  # the absurd collar
    # arms
    if arm == "down":
        d.line((10, 19, 8, 34), fill=SUIT, width=3)
        d.line((24, 19, 26, 34), fill=SUIT, width=3)
        d.rectangle((7, 34, 9, 36), fill=SKIN)
        d.rectangle((25, 34, 27, 36), fill=SKIN)
    elif arm == "raise":
        d.line((10, 19, 8, 34), fill=SUIT, width=3)
        d.rectangle((7, 34, 9, 36), fill=SKIN)
        d.line((24, 19, 30, 6), fill=SUIT, width=3)
        d.rectangle((29, 2, 32, 6), fill=SKIN)
    elif arm == "point":
        d.line((10, 19, 8, 34), fill=SUIT, width=3)
        d.rectangle((7, 34, 9, 36), fill=SKIN)
        d.line((24, 19, 32, 22), fill=SUIT, width=3)
        d.rectangle((31, 21, 33, 23), fill=SKIN)
    if holding:
        d.ellipse((24, 30, 29, 35), fill=HL, outline=OUT)
    # head
    d.ellipse((11, 2, 23, 16), fill=SKIN, outline=(150, 110, 90))
    # hair
    if messy:
        for hx, hy in ((11, 1), (13, -1), (16, 0), (19, -1), (22, 1), (24, 4), (10, 5)):
            d.line((17, 4, hx, hy), fill=HAIR, width=2)
        d.chord((11, 1, 23, 9), 180, 360, fill=HAIR)
    else:
        d.chord((11, 1, 23, 10), 180, 360, fill=HAIR)
        d.polygon(((11, 6), (23, 3), (25, 6), (14, 7)), fill=HAIR)
    # chrome visor
    d.rectangle((12, 8, 22, 10), fill=(196, 206, 222))
    d.line((13, 8, 16, 8), fill=(255, 255, 255))
    d.point((20, 9), fill=(255, 60, 70))
    # mouth
    if mouth == "smirk":
        d.line((15, 13, 19, 12), fill=(110, 60, 50))
    elif mouth == "open":
        d.rectangle((16, 12, 18, 14), fill=(110, 30, 40))
    elif mouth == "flat":
        d.line((15, 13, 19, 13), fill=(110, 60, 50))
    if silhouette:
        a = im.getchannel("A")
        im = Image.new("RGBA", im.size, (8, 6, 12, 255))
        im.putalpha(a)
    return im

@lru_cache(maxsize=None)
def cdo_img(k=2, **kw):
    im = cdo_base(**kw)
    return im.resize((im.width * k, im.height * k), Image.NEAREST) if k != 1 else im

def cdo(img, x, y, k=2, **kw):
    put(img, cdo_img(k=k, **kw), x, y)

# ----------------------------------------------------------------------------------------------- backgrounds

def bands(img, top, bottom, y0, y1, n=10):
    d = ImageDraw.Draw(img)
    for i in range(n):
        a, b = y0 + (y1 - y0) * i // n, y0 + (y1 - y0) * (i + 1) // n
        d.rectangle((0, a, W, b), fill=mix(top, bottom, i / (n - 1)))

def cloud(d, x, y, s=1.0, col=(255, 255, 255)):
    for dx, dy, r in ((0, 0, 9), (10, -4, 11), (22, 0, 9), (12, 3, 9)):
        d.ellipse((x + dx * s - r * s, y + dy * s - r * s, x + dx * s + r * s, y + dy * s + r * s), fill=col)

@lru_cache(maxsize=None)
def meadow():
    img = Image.new("RGBA", (W, H))
    bands(img, (96, 170, 248), (196, 232, 255), 0, 200, 9)
    d = ImageDraw.Draw(img)
    d.ellipse((380, 24, 412, 56), fill=(255, 236, 150))
    d.ellipse((386, 30, 406, 50), fill=(255, 248, 200))
    for x, y, s in ((40, 50, 1.0), (170, 34, 0.8), (290, 66, 1.1)):
        cloud(d, x, y, s)
    # hills
    for base, amp, freq, ph, col in ((176, 14, 0.018, 0.4, (124, 196, 100)), (192, 10, 0.026, 2.0, (96, 172, 80))):
        pts = [(x, base - amp * math.sin(x * freq + ph)) for x in range(0, W + 8, 8)]
        d.polygon(pts + [(W, H), (0, H)], fill=col)
    d.rectangle((0, 214, W, H), fill=(82, 150, 66))
    d.line((0, 214, W, 214), fill=(120, 196, 96))
    rnd = random.Random(7)
    for _ in range(70):
        x, y = rnd.randrange(W), rnd.randrange(218, H)
        d.point((x, y), fill=(66, 128, 54))
    for _ in range(18):
        x, y = rnd.randrange(W), rnd.randrange(220, H - 4)
        col = rnd.choice(((255, 240, 120), (255, 170, 200), (255, 255, 255)))
        d.point((x, y), fill=col)
        d.point((x, y + 1), fill=(60, 120, 50))
    return img

@lru_cache(maxsize=None)
def battlefield(tint=0):
    img = Image.new("RGBA", (W, H))
    bands(img, (30, 12, 46), (120, 40, 64), 0, 196, 10)
    d = ImageDraw.Draw(img)
    rnd = random.Random(3)
    for _ in range(40):
        d.point((rnd.randrange(W), rnd.randrange(120)), fill=(220, 200, 240))
    # distant ruins
    for x in range(10, W, 46):
        h = rnd.randrange(20, 60)
        d.rectangle((x, 196 - h, x + 12, 196), fill=(48, 20, 50))
        d.rectangle((x - 2, 196 - h - 3, x + 14, 196 - h), fill=(48, 20, 50))
    d.rectangle((0, 196, W, H), fill=(58, 44, 58))
    for y in range(200, H, 8):
        d.line((0, y, W, y), fill=(70, 54, 70))
    for x in range(-200, W + 200, 24):
        d.line((W / 2 + (x - W / 2) * 0.3, 196, x, H), fill=(70, 54, 70))
    d.line((0, 196, W, 196), fill=(120, 80, 110))
    return img

def anime_sky(t):
    """Swirling storm: rotating rays over dark clouds, with lightning now and then."""
    img = Image.new("RGBA", (W, H), (20, 8, 36, 255))
    d = ImageDraw.Draw(img)
    cx, cy = W / 2, 96
    for i in range(24):
        a = t * 0.9 + i * math.tau / 24
        col = (60, 20, 90) if i % 2 else (34, 12, 60)
        d.polygon(((cx, cy), (cx + 600 * math.cos(a), cy + 600 * math.sin(a)), (cx + 600 * math.cos(a + 0.13), cy + 600 * math.sin(a + 0.13))), fill=col)
    rnd = random.Random(11)
    for i in range(14):
        x = (rnd.randrange(W) + t * (20 + i * 3)) % (W + 80) - 40
        y = rnd.randrange(10, 120)
        cloud(d, x, y, 1.2 + rnd.random(), (52, 30, 74))
    if (t * 2.3) % 1 < 0.08:
        rnd2 = random.Random(int(t * 2.3))
        x = rnd2.randrange(40, W - 40)
        pts = [(x, 0)]
        y = 0
        while y < 190:
            y += rnd2.randrange(12, 26)
            x += rnd2.randrange(-14, 15)
            pts.append((x, y))
        d.line(pts, fill=(250, 250, 255), width=2)
        d.line(pts, fill=(170, 210, 255), width=1)
    d.rectangle((0, 196, W, H), fill=(40, 28, 52))
    d.line((0, 196, W, 196), fill=(150, 110, 200))
    return img

# ----------------------------------------------------------------------------------------------- UI pieces

def box(img, x0, y0, x1, y1, top=(36, 56, 150), bottom=(10, 18, 70), border=(255, 255, 255), inner=(140, 170, 255)):
    """A 16-bit dialogue box: banded blue, white frame, light inner frame."""
    d = ImageDraw.Draw(img)
    n = max(1, (y1 - y0) // 4)
    for i in range(n):
        a, b = y0 + (y1 - y0) * i // n, y0 + (y1 - y0) * (i + 1) // n
        d.rectangle((x0, a, x1, b), fill=mix(top, bottom, i / max(1, n - 1)))
    d.rectangle((x0, y0, x1, y1), outline=border)
    d.rectangle((x0 + 2, y0 + 2, x1 - 2, y1 - 2), outline=inner)

SPEAKER_COL = {"tot": (255, 214, 120), "gary": (255, 214, 120), "cdo": (210, 150, 255), "dot": (255, 120, 130), "judge": (140, 230, 160)}

def dialogue(img, speaker, s, lt, cps=28, where="bottom", size=13):
    """A dialogue box typing `s` at `cps` characters a second; `lt` is seconds since it opened."""
    f = pix(size)
    lines = wrap(s, f, 400)
    h = 20 + 16 * len(lines)
    if where == "bottom":
        x0, y0 = 24, H - h - 10
    else:
        x0, y0 = 24, 12
    x1, y1 = W - 24, y0 + h
    # opens with a quick vertical grow
    g = ease_out(seg(lt, 0, 0.08))
    if g < 1:
        mid = (y0 + y1) // 2
        y0, y1 = int(mid - (mid - y0) * g), int(mid + (y1 - mid) * g)
        if y1 - y0 < 4:
            return
        box(img, x0, y0, x1, y1)
        return
    box(img, x0, y0, x1, y1)
    name = speaker.upper()
    nf = pix(10)
    nw = int(nf.getlength(name)) + 12
    box(img, x0 + 8, y0 - 11, x0 + 8 + nw, y0 + 3, top=(20, 30, 90), bottom=(20, 30, 90))
    text(img, (x0 + 14, y0 - 9), name, 10, SPEAKER_COL.get(speaker.split()[0].lower(), (255, 255, 255)), f=nf)
    shown = int(max(0, lt - 0.08) * cps)
    left = shown
    for i, line in enumerate(lines):
        part = line[: max(0, left)]
        left -= len(line) + 1
        text(img, (x0 + 12, y0 + 9 + 16 * i), part, size, (255, 255, 255), f=f)
    if shown >= len(s) and int(lt * 3) % 2 == 0:
        d = ImageDraw.Draw(img)
        cx, cy = x1 - 12, y1 - 7
        d.polygon(((cx - 3, cy - 2), (cx + 3, cy - 2), (cx, cy + 2)), fill=(255, 255, 255))

def hp_bar(img, x, y, w, frac, label, col=(220, 60, 80), size=10):
    d = ImageDraw.Draw(img)
    text(img, (x, y - 12), label, size, (255, 255, 255))
    d.rectangle((x - 1, y - 1, x + w + 1, y + 7), fill=(0, 0, 0), outline=(255, 255, 255))
    fw = int(w * clamp01(frac))
    for i in range(0, fw, 4):
        d.rectangle((x + i, y + 1, x + min(fw, i + 3) - 1, y + 5), fill=col)
    d.line((x, y + 1, x + fw - 1, y + 1), fill=mix(col, (255, 255, 255), 0.5))

def banner(img, s, lt, y=26, col=(255, 70, 90), size=16, dur=0.9):
    """An attack name sliding in across a black band."""
    a = ease_out(seg(lt, 0, 0.12))
    d = ImageDraw.Draw(img)
    hgt = size + 10
    yy = y
    d.rectangle((0, yy, int(W * a), yy + hgt), fill=(0, 0, 0))
    d.line((0, yy, int(W * a), yy), fill=col)
    d.line((0, yy + hgt, int(W * a), yy + hgt), fill=col)
    if a >= 1:
        text(img, (W // 2, yy + hgt // 2 + 1), s, size, (255, 255, 255), anchor="mm", stroke=2, stroke_fill=col)

def flash(img, a, col=(255, 255, 255)):
    if a <= 0:
        return
    layer = Image.new("RGBA", img.size, col + (int(255 * clamp01(a)),))
    img.alpha_composite(layer)

def tint(img, col, a):
    flash(img, a, col)

def explosion(img, cx, cy, lt, size=40, seed=1):
    """A pixel blast: flash core, expanding rings, debris."""
    if lt < 0 or lt > 1.0:
        return
    d = ImageDraw.Draw(img)
    r = size * ease_out(lt / 0.5)
    if lt < 0.6:
        for rr, col in ((r, (255, 120, 40)), (r * 0.75, (255, 200, 60)), (r * 0.45, (255, 250, 220))):
            d.ellipse((cx - rr, cy - rr * 0.8, cx + rr, cy + rr * 0.8), fill=col)
    else:
        a = 1 - seg(lt, 0.6, 1.0)
        for i in range(10):
            ang = i * 0.63 + seed
            rr = r * (0.6 + 0.4 * math.sin(i * 1.7))
            sx, sy = cx + rr * math.cos(ang) * 0.9, cy + rr * math.sin(ang) * 0.6
            sz = 10 * a
            d.ellipse((sx - sz, sy - sz, sx + sz, sy + sz), fill=mix((80, 70, 80), (150, 140, 150), a))
    rnd = random.Random(seed)
    for i in range(24):
        ang = rnd.random() * math.tau
        sp = size * (1.2 + rnd.random() * 1.8)
        x = cx + math.cos(ang) * sp * lt
        y = cy + math.sin(ang) * sp * lt * 0.7 + 120 * lt * lt
        col = rnd.choice(((255, 220, 80), (255, 140, 40), (255, 255, 255)))
        if lt < 0.85:
            d.rectangle((x, y, x + 1, y + 1), fill=col)

def sparkle(img, x, y, lt, col=(255, 255, 200)):
    if lt < 0 or lt > 0.6:
        return
    d = ImageDraw.Draw(img)
    s = int(6 * math.sin(lt / 0.6 * math.pi))
    d.line((x - s, y, x + s, y), fill=col)
    d.line((x, y - s, x, y + s), fill=col)

def trophy(img, x, y):
    d = ImageDraw.Draw(img)
    d.rectangle((x + 2, y, x + 11, y + 6), fill=GOLD)
    d.arc((x - 2, y, x + 4, y + 6), 90, 270, fill=GOLD)
    d.arc((x + 9, y, x + 15, y + 6), 270, 90, fill=GOLD)
    d.rectangle((x + 5, y + 7, x + 8, y + 9), fill=GOLD)
    d.rectangle((x + 3, y + 10, x + 10, y + 11), fill=(180, 140, 40))
    d.point((x + 4, y + 1), fill=(255, 250, 200))

def glitch(img, amount, seed):
    """Slice the frame into bands and shove them sideways, with a colour split."""
    if amount <= 0:
        return img
    rnd = random.Random(seed)
    arr = np.array(img)
    for _ in range(int(6 + 10 * amount)):
        y = rnd.randrange(H)
        h = rnd.randrange(2, 14)
        dx = int(rnd.randrange(-30, 31) * amount)
        arr[y : y + h] = np.roll(arr[y : y + h], dx, axis=1)
    out = arr.copy()
    sh = int(3 * amount) + 1
    out[..., 0] = np.roll(arr[..., 0], sh, axis=1)
    out[..., 2] = np.roll(arr[..., 2], -sh, axis=1)
    return Image.fromarray(out, "RGBA")

def desaturate(img, a):
    if a <= 0:
        return img
    g = img.convert("L").convert("RGBA")
    return Image.blend(img, g, clamp01(a))
