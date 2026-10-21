"""Pixel art for the vertical short: Agent Garrett, the bots, the boss, tot gear, backgrounds, effects.

Everything is drawn on a 270x480 canvas and scaled 4x (to 1080x1920) at the end. The tot itself, the text
helpers and the little maths come from ../render/gfx.py, so the tots look the same as in the release trailer.
"""
import math
import os
import random
import sys
from functools import lru_cache

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "render"))
import gfx  # noqa: E402
from gfx import (clamp01, seg, ease_out, ease_in, ease_io, lerp, mix, bounce, font, pix, mono, big, text, wrap,  # noqa: E402,F401
                 glow_img, put, box, explosion, sparkle, tot_base, hp_bar, OUT)

W, H = 270, 480
GROUND = 360

# ----------------------------------------------------------------------------------------------- palette

ORANGE = (255, 69, 0)      # the upvote
PERI = (113, 147, 255)     # the downvote
METAL = (170, 176, 194)
METAL_D = (118, 124, 146)
METAL_L = (220, 226, 238)
BOT_OUT = (38, 40, 54)
NOIR = (11, 9, 17)
NOIR2 = (28, 24, 40)
EYE_G = (255, 214, 96)
GOLD = (255, 204, 64)
GOLD_D = (178, 120, 20)
GRASS = (92, 196, 72)
GRASS_D = (54, 140, 50)

# ----------------------------------------------------------------------------------------------- canvas helpers

BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16.0


@lru_cache(maxsize=None)
def grad_img(stops, h, levels=10, w=W):
    """A w x h vertical gradient through `stops` ((pos, rgb), ...), banded into `levels` and Bayer-dithered
    between bands, the way a 16-bit game fakes a smooth sky."""
    t = np.linspace(0, 1, h)[:, None] * np.ones((1, w))
    thr = np.tile(BAYER, (h // 4 + 1, w // 4 + 1))[:h, :w]
    q = np.floor(t * (levels - 1) + thr) / (levels - 1)
    ps = np.array([p for p, _ in stops])
    cs = np.array([c for _, c in stops], float)
    arr = np.zeros((h, w, 4), np.uint8)
    for i in range(3):
        arr[..., i] = np.interp(q, ps, cs[:, i]).astype(np.uint8)
    arr[..., 3] = 255
    return Image.fromarray(arr, "RGBA")


def canvas(col=(0, 0, 0)):
    return Image.new("RGBA", (W, H), col + (255,))


def layer():
    return Image.new("RGBA", (W, H), (0, 0, 0, 0))


def alpha_rect(img, xy, col, a):
    lay = layer()
    ImageDraw.Draw(lay).rectangle(xy, fill=col + (int(255 * clamp01(a)),))
    img.alpha_composite(lay)


def comp(img, lay, dx, dy):
    """alpha_composite `lay` shifted by (dx, dy), either sign."""
    sx, sy = max(0, -int(dx)), max(0, -int(dy))
    if sx >= lay.width or sy >= lay.height:
        return
    img.alpha_composite(lay, (max(0, int(dx)), max(0, int(dy))), (sx, sy))


def flash(img, a, col=(255, 255, 255)):
    if a > 0:
        img.alpha_composite(Image.new("RGBA", img.size, col + (int(255 * clamp01(a)),)))


def tinted(im, col, a=1.0):
    """Push every opaque pixel of a sprite toward `col` (a hit flash, a silhouette)."""
    arr = np.array(im).astype(float)
    arr[..., :3] = arr[..., :3] * (1 - a) + np.array(col, float) * a
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def rim(im, col, dx=1, dy=0):
    """Light the edge of a silhouette from one side: an opaque pixel whose neighbour toward the light is empty."""
    arr = np.array(im)
    a = arr[..., 3] > 0
    nb = np.zeros_like(a)
    h, w = a.shape
    ys, xs = slice(max(0, -dy), h - max(0, dy)), slice(max(0, -dx), w - max(0, dx))
    yd, xd = slice(max(0, dy), h - max(0, -dy)), slice(max(0, dx), w - max(0, -dx))
    nb[ys, xs] = a[yd, xd]
    edge = a & ~nb
    arr[edge, :3] = col
    return Image.fromarray(arr, "RGBA")


def scaled(im, k):
    return im if k == 1 else im.resize((im.width * k, im.height * k), Image.NEAREST)


def squashed(im, sx, sy):
    return im.resize((max(1, int(im.width * sx)), max(1, int(im.height * sy))), Image.NEAREST)


def sepia(img, a=1.0):
    if a <= 0:
        return img
    arr = np.array(img).astype(float)
    g = arr[..., 0] * 0.3 + arr[..., 1] * 0.59 + arr[..., 2] * 0.11
    sep = np.stack([g * 1.07 + 20, g * 0.9 + 8, g * 0.68], -1)
    arr[..., :3] = arr[..., :3] * (1 - a) + np.clip(sep, 0, 255) * a
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def impact(img, thr=96, fg=(255, 255, 255), bg=(0, 0, 0)):
    """An anime impact frame: the whole picture slammed into two flat tones for a frame or two."""
    g = np.array(img.convert("L")) > thr
    arr = np.zeros((img.height, img.width, 4), np.uint8)
    arr[g, :3] = bg
    arr[~g, :3] = fg
    arr[..., 3] = 255
    return Image.fromarray(arr, "RGBA")


def glitch(img, amount, seed):
    if amount <= 0:
        return img
    rnd = random.Random(seed)
    arr = np.array(img)
    for _ in range(int(6 + 12 * amount)):
        y = rnd.randrange(H)
        h = rnd.randrange(2, 16)
        arr[y:y + h] = np.roll(arr[y:y + h], int(rnd.randrange(-24, 25) * amount), axis=1)
    out = arr.copy()
    sh = int(3 * amount) + 1
    out[..., 0] = np.roll(arr[..., 0], sh, axis=1)
    out[..., 2] = np.roll(arr[..., 2], -sh, axis=1)
    return Image.fromarray(out, "RGBA")


def speed_lines(img, cx, cy, seed, n=34, col=(255, 255, 255), a=0.55, r0=70):
    lay = layer()
    d = ImageDraw.Draw(lay)
    rnd = random.Random(seed)
    for _ in range(n):
        ang = rnd.random() * math.tau
        w = 0.012 + rnd.random() * 0.02
        r1 = r0 + rnd.random() * 60
        pts = ((cx + r1 * math.cos(ang), cy + r1 * math.sin(ang)), (cx + 600 * math.cos(ang - w), cy + 600 * math.sin(ang - w)),
               (cx + 600 * math.cos(ang + w), cy + 600 * math.sin(ang + w)))
        d.polygon(pts, fill=col + (int(255 * a),))
    img.alpha_composite(lay)


def vlines(img, t, col=(255, 230, 200), n=14, a=0.5, speed=900, seed=3):
    """Vertical action streaks (a fall, a charge)."""
    lay = layer()
    d = ImageDraw.Draw(lay)
    rnd = random.Random(seed)
    for _ in range(n):
        x = rnd.randrange(W)
        ln = rnd.randrange(30, 90)
        y = (rnd.randrange(H) + t * speed) % (H + ln) - ln
        d.line((x, y, x, y + ln), fill=col + (int(255 * a),))
    img.alpha_composite(lay)


def rain(img, t, n=90, a=0.45, col=(170, 190, 240), seed=5):
    lay = layer()
    d = ImageDraw.Draw(lay)
    rnd = random.Random(seed)
    for _ in range(n):
        x0 = rnd.randrange(-60, W)
        sp = 380 + rnd.randrange(260)
        y = (rnd.randrange(H) + t * sp) % (H + 20) - 20
        x = x0 + (y * 0.25)
        d.line((x, y, x + 3, y + 11), fill=col + (int(255 * a * (0.5 + 0.5 * rnd.random())),))
    img.alpha_composite(lay)


def bolt(img, seed, x0=None, y1=300, col=(240, 240, 255), width=2):
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    x = x0 if x0 is not None else rnd.randrange(30, W - 30)
    pts, y = [(x, 0)], 0
    while y < y1:
        y += rnd.randrange(14, 30)
        x += rnd.randrange(-16, 17)
        pts.append((x, y))
    d.line(pts, fill=(160, 200, 255), width=width + 2)
    d.line(pts, fill=col, width=width)


def embers(img, t, n=40, seed=8, col=(255, 170, 60), y0=0, y1=H):
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    for _ in range(n):
        x = (rnd.randrange(W) + 14 * math.sin(t * 1.3 + rnd.random() * 6)) % W
        sp = 20 + rnd.randrange(40)
        y = y1 - ((rnd.randrange(y1 - y0) + t * sp) % (y1 - y0))
        c = col if rnd.random() > 0.3 else (255, 230, 140)
        d.point((x, y), fill=c)


def smoke(img, t, x, y, scale=1.0, seed=1, col=(40, 30, 36), a=0.7, n=7):
    lay = layer()
    d = ImageDraw.Draw(lay)
    rnd = random.Random(seed)
    for i in range(n):
        u = ((t * 0.25 + i / n + rnd.random() * 0.1) % 1.0)
        r = (6 + 22 * u) * scale
        cx = x + (14 * u + 6 * math.sin(i * 2 + t)) * scale
        cy = y - 150 * u * scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=col + (int(255 * a * (1 - u)),))
    img.alpha_composite(lay)


def fire(img, x, y, t, s=1.0, seed=0):
    d = ImageDraw.Draw(img)
    for i, (dx, hh) in enumerate(((-5, 12), (0, 18), (5, 11))):
        fh = (hh + 4 * math.sin(t * 15 + i * 2 + seed)) * s
        d.polygon(((x + dx * s - 5 * s, y), (x + dx * s + 5 * s, y), (x + dx * s, y - fh)), fill=(255, 110, 30))
        d.polygon(((x + dx * s - 3 * s, y), (x + dx * s + 3 * s, y), (x + dx * s, y - fh * 0.6)), fill=(255, 220, 90))


# ----------------------------------------------------------------------------------------------- text and UI

def label(img, xy, s, size=10, fill=(255, 255, 255), anchor="la", stroke=1, stroke_fill=(0, 0, 0), f=None, alpha=1.0):
    text(img, xy, s, size, fill, anchor, f, stroke, stroke_fill, alpha)


def headline(img, s, y, size=30, fill=(255, 255, 255), stroke_fill=(0, 0, 0), pop=1.0, stroke=3, x=W // 2, maxw=None):
    """A big Impact headline, popped in with an overshoot (pop runs 0 -> 1)."""
    sc = bounce(pop) if pop < 1 else 1.0
    sz = max(4, int(size * sc))
    f = big(sz)
    # shrink to fit the width
    while f.getlength(s) > (maxw or W - 16) and sz > 8:
        sz -= 1
        f = big(sz)
    text(img, (x, y), s, f=f, fill=fill, anchor="mm", stroke=stroke, stroke_fill=stroke_fill)


@lru_cache(maxsize=None)
def bubble_img(s, size=10, shout=False, tail="down", fill=(255, 255, 255), ink=(16, 14, 22), maxw=150):
    """A comic speech bubble with a tail, as a sprite; the tail tip is the sprite's bottom centre (or top for
    tail='up')."""
    f = pix(size)
    lines = wrap(s, f, maxw)
    tw = int(max(f.getlength(ln) for ln in lines))
    lh = size + 3
    th = lh * len(lines)
    pad = 5
    bw, bh = tw + pad * 2, th + pad * 2 - 2
    tl = 7
    sp = 9 if shout else 2  # room for the spikes of a shout
    im = Image.new("RGBA", (bw + 2 * sp, bh + tl + 2 * sp), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    oy = sp if tail == "down" else tl + sp
    x0, y0, x1, y1 = sp, oy, sp + bw - 1, oy + bh - 1
    cx = (x0 + x1) // 2
    if shout:
        pts = []
        n = max(14, (bw + bh) // 6) // 2 * 2
        cy = (y0 + y1) / 2
        for i in range(n):
            a = i / n * math.tau
            r = 1.0 if i % 2 == 0 else 0.0
            rx = bw / 2 * 1.08 + r * (sp - 1) * 1.0 + (0 if r else -bw * 0.04)
            ry = bh / 2 * 1.12 + r * (sp - 1) * 0.9
            pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
        d.polygon(pts, fill=fill, outline=ink)
        d.rectangle((x0 + 1, y0 + 1, x1 - 1, y1 - 1), fill=fill)
    else:
        d.rounded_rectangle((x0, y0, x1, y1), radius=5, fill=fill, outline=ink)
    if tail == "down":
        d.polygon(((cx - 4, y1 - 1), (cx + 3, y1 - 1), (cx, y1 + tl)), fill=fill)
        d.line((cx - 4, y1, cx, y1 + tl), fill=ink)
        d.line((cx + 3, y1, cx, y1 + tl), fill=ink)
    else:
        d.polygon(((cx - 4, y0 + 1), (cx + 3, y0 + 1), (cx, y0 - tl)), fill=fill)
        d.line((cx - 4, y0, cx, y0 - tl), fill=ink)
        d.line((cx + 3, y0, cx, y0 - tl), fill=ink)
    dd = gfx.draw(im)
    for i, ln in enumerate(lines):
        dd.text((cx, y0 + pad - 1 + i * lh), ln, font=f, fill=ink, anchor="ma")
    return im


def bubble(img, x, y, s, lt, size=10, shout=False, tail="down", fill=(255, 255, 255), ink=(16, 14, 22), maxw=150, dur=1.2):
    """Pop a speech bubble in with its tail tip at (x, y); lt is seconds since it appeared, gone after `dur`."""
    if lt < 0 or lt > dur:
        return
    im = bubble_img(s, size, shout, tail, fill, ink, maxw)
    sc = bounce(seg(lt, 0, 0.18)) if lt < 0.18 else 1.0
    sc = max(0.3, sc if lt >= 0.05 else 0.5 + lt * 8)
    if abs(sc - 1) > 0.02:
        im = squashed(im, sc, sc)
    px = int(min(max(x - im.width / 2, 2), W - im.width - 2))
    py = int(y - im.height) if tail == "down" else int(y)
    img.paste(im, (px, py), im)


def banner(img, s, lt, y=40, col=(255, 60, 70), size=19, sub=None, sub_col=(255, 255, 255)):
    """An attack name slammed across a black band that wipes in from the left."""
    a = ease_out(seg(lt, 0, 0.14))
    hgt = size + 12 + (12 if sub else 0)
    d = ImageDraw.Draw(img)
    x1 = int(W * a)
    d.polygon(((0, y), (x1 + 10, y), (x1, y + hgt), (0, y + hgt)), fill=(8, 6, 12))
    d.line((0, y, x1 + 10, y), fill=col, width=2)
    d.line((0, y + hgt, x1, y + hgt), fill=col, width=2)
    if a >= 1:
        sc = bounce(seg(lt, 0.14, 0.32))
        f = big(max(6, int(size * sc)))
        while f.getlength(s) > W - 14:
            size -= 1
            f = big(max(6, int(size * sc)))
        text(img, (W // 2, y + 4 + size // 2 + 2), s, f=f, fill=(255, 255, 255), anchor="mm", stroke=2, stroke_fill=col)
        if sub:
            text(img, (W // 2, y + hgt - 8), sub, 9, sub_col, anchor="mm", stroke=1)


def stamp(img, x, y, s, lt, col=(220, 30, 40), size=16, angle=-12):
    """A rubber stamp thumped onto the picture (BANNED, REMOVED...)."""
    if lt < 0:
        return
    im = _stamp_img(s, col, size, angle)
    sc = lerp(2.2, 1.0, ease_in(seg(lt, 0, 0.1)))
    if sc > 1.01:
        im = squashed(im, sc, sc)
    put(img, im, x, y, anchor="center")


@lru_cache(maxsize=None)
def _stamp_img(s, col, size, angle):
    f = big(size)
    tw = int(f.getlength(s))
    im = Image.new("RGBA", (tw + 14, size + 12), (0, 0, 0, 0))
    d = gfx.draw(im)
    d.rectangle((1, 1, tw + 12, size + 10), outline=col, width=2)
    d.text((tw // 2 + 7, size // 2 + 6), s, font=f, fill=col, anchor="mm")
    return im.rotate(angle, resample=Image.NEAREST, expand=True)


def damage(img, x, y, s, lt, col=(255, 248, 120), stroke_fill=(200, 20, 30), size=22):
    if lt < 0 or lt > 1.2:
        return
    sc = bounce(seg(lt, 0, 0.18))
    a = 1 - seg(lt, 0.8, 1.2)
    text(img, (x, y - 26 * ease_out(seg(lt, 0, 0.9))), s, f=big(max(5, int(size * sc))), fill=col, anchor="mm", stroke=2,
         stroke_fill=stroke_fill, alpha=a)


def stars(img, x, y, t, r=10, n=3, col=(255, 236, 90)):
    d = ImageDraw.Draw(img)
    for i in range(n):
        a = t * 6 + i * math.tau / n
        sx, sy = x + r * math.cos(a), y + r * 0.4 * math.sin(a)
        d.line((sx - 2, sy, sx + 2, sy), fill=col)
        d.line((sx, sy - 2, sx, sy + 2), fill=col)


SPEAKER_NAME = {"tot": "tater tot"}
SPEAKER_COL = {"garrett": (255, 214, 96), "tot": (255, 190, 110), "bot": (255, 110, 110), "mod-bot": (120, 230, 140),
               "boss": (210, 150, 255), "scientist": (170, 230, 255), "human": (230, 230, 230), "ackshually-bot": (255, 110, 110)}


def dialogue(img, speaker, s, lt, where="bottom", cps=30, size=11):
    """A 16-bit dialogue box typing `s` (lt: seconds since it opened). Garrett talks over a radio, so his box
    gets his portrait beside it."""
    f = pix(size)
    portrait = speaker.split()[0] == "garrett"
    tx0 = 66 if portrait else 18
    lines = wrap(s, f, W - tx0 - 16)
    h = max(18 + 14 * len(lines), 50 if portrait else 0)
    if img.height < H:  # the square cut: subtitles at the bottom unless a shot asks for the top
        y0 = {"top": 42, "high": 24}.get(where, img.height - h - 6)
    else:
        y0 = {"bottom": 318, "top": 100, "low": 384}.get(where, 318)
    x0, x1, y1 = 8, W - 8, y0 + h
    g = ease_out(seg(lt, 0, 0.08))
    if g < 1:
        mid = (y0 + y1) // 2
        a, b = int(mid - (mid - y0) * g), int(mid + (y1 - mid) * g)
        if b - a >= 4:
            box(img, x0, a, x1, b)
        return
    if portrait:
        box(img, x0, y0, x1, y1, top=(24, 22, 40), bottom=(8, 8, 18), border=(255, 214, 96), inner=(120, 96, 40))
        codec(img, x0 + 6, y0 + 6, lt)
    else:
        box(img, x0, y0, x1, y1)
    name = SPEAKER_NAME.get(speaker, speaker).upper()
    nf = pix(9)
    nw = int(nf.getlength(name)) + 12
    box(img, x0 + 8, y0 - 11, x0 + 8 + nw, y0 + 3, top=(20, 30, 90), bottom=(20, 30, 90),
        border=(255, 214, 96) if portrait else (255, 255, 255))
    text(img, (x0 + 14, y0 - 9), name, 9, SPEAKER_COL.get(speaker.split()[0].lower(), (255, 255, 255)), f=nf)
    shown = int(max(0, lt - 0.08) * cps)
    left = shown
    for i, line in enumerate(lines):
        part = line[:max(0, left)]
        left -= len(line) + 1
        text(img, (x0 + tx0 - 8 + 2, y0 + 8 + 14 * i), part, size, (255, 255, 255), f=f)
    if shown >= len(s) and int(lt * 3) % 2 == 0:
        d = ImageDraw.Draw(img)
        cx, cy = x1 - 10, y1 - 7
        d.polygon(((cx - 3, cy - 2), (cx + 3, cy - 2), (cx, cy + 2)), fill=(255, 255, 255))


def codec(img, x, y, lt, w=44, h=38):
    """Agent Garrett on the radio: his hat and eyes in a small scan-lined window."""
    win = grad_img(((0, (40, 70, 70)), (1, (12, 26, 30))), h - 1, 5, w - 1)
    img.paste(win, (x + 1, y + 1))
    d = ImageDraw.Draw(img)
    d.rectangle((x, y, x + w, y + h), outline=(255, 214, 96))
    face = garrett_face(1, rim_col=(120, 200, 190))
    fx = x + w // 2 - face.width // 2
    img.paste(face, (fx, y + h - face.height), face)
    lay = layer()
    ld = ImageDraw.Draw(lay)
    for yy in range(y + 2, y + h, 3):
        ld.line((x + 1, yy, x + w - 1, yy), fill=(0, 0, 0, 90))
    img.alpha_composite(lay)
    ey = y + h - face.height + 16
    put(img, glow_img(4, EYE_G, 0.7), fx + 17, ey, anchor="center")
    put(img, glow_img(4, EYE_G, 0.7), fx + 23, ey, anchor="center")
    if int(lt * 4) % 2 == 0:
        d.ellipse((x + w - 6, y + 3, x + w - 3, y + 6), fill=(255, 60, 70))
    if lt < 0.2:
        rnd = random.Random(int(lt * 60))
        for _ in range(60):
            d.point((x + rnd.randrange(w), y + rnd.randrange(h)), fill=(200, 200, 200))


# ----------------------------------------------------------------------------------------------- Agent Garrett

GOX, GOY = 12, 8  # where the 40x80 figure sits inside its padded canvas


@lru_cache(maxsize=None)
def garrett_base(pose="stand", flap=0, eyes=True):
    """Agent Garrett: a dark figure in a wide-brim hat and a long coat, collar up, two warm eyes under the brim.
    Drawn in a 40x80 frame (feet on the bottom row) inside a padded 64x88 canvas so arms can reach out."""
    im = Image.new("RGBA", (64, 88), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def P(*pts):
        return [(px + GOX, py + GOY) for px, py in pts]

    f = flap
    # legs and shoes
    d.rectangle(P((14, 66), (18, 77)), fill=NOIR)
    d.rectangle(P((22, 66), (26, 77)), fill=NOIR)
    d.rectangle(P((12, 77), (18, 79)), fill=NOIR)
    d.rectangle(P((22, 77), (28, 79)), fill=NOIR)
    # the coat: shoulders to a flared hem that swings in the wind
    d.polygon(P((9, 23), (31, 23), (34 + f, 68), (20, 70), (6 + f // 2, 68)), fill=NOIR)
    d.polygon(P((24, 58), (34 + f, 68), (37 + f + f // 2, 72), (25, 69)), fill=NOIR)
    d.line(P((20, 25), (20, 68)), fill=NOIR2)
    d.line(P((10, 44), (30, 44)), fill=NOIR2)
    d.line(P((25, 30), (27, 66)), fill=NOIR2)
    # collar up
    d.polygon(P((10, 17), (16, 22), (13, 30), (8, 23)), fill=NOIR)
    d.polygon(P((30, 17), (24, 22), (27, 30), (32, 23)), fill=NOIR)
    # head, hat crown with a pinch, band, and a wide tilted brim
    d.ellipse(P((14, 9), (26, 23)), fill=NOIR)
    d.polygon(P((12, 10), (13, 3), (16, 0), (20, 2), (24, 0), (27, 3), (28, 10)), fill=NOIR)
    d.line(P((13, 8), (27, 8)), fill=NOIR2)
    d.polygon(P((2, 13), (9, 9), (31, 9), (38, 12), (32, 14), (8, 14)), fill=NOIR)
    # arms
    if pose == "stand":
        d.polygon(P((9, 23), (13, 25), (11, 47), (7, 46)), fill=NOIR)
        d.polygon(P((31, 23), (27, 25), (29, 47), (33, 46)), fill=NOIR)
    elif pose == "raise":
        d.polygon(P((9, 23), (13, 25), (11, 47), (7, 46)), fill=NOIR)
        d.polygon(P((28, 23), (32, 24), (40, -3), (36, -4)), fill=NOIR)
        d.rectangle(P((36, -7), (40, -3)), fill=NOIR)
        d.line(P((39, -8), (39, -11)), fill=NOIR, width=2)
    elif pose == "point":
        d.polygon(P((9, 23), (13, 25), (11, 47), (7, 46)), fill=NOIR)
        d.polygon(P((28, 23), (32, 23), (47, 25), (47, 29), (29, 30)), fill=NOIR)
        d.rectangle(P((47, 24), (50, 28)), fill=NOIR)
        d.line(P((50, 25), (52, 25)), fill=NOIR)
    elif pose == "conduct":
        d.polygon(P((12, 23), (8, 26), (-8, 14), (-6, 11)), fill=NOIR)
        d.rectangle(P((-10, 9), (-7, 12)), fill=NOIR)
        d.polygon(P((28, 23), (32, 26), (48, 14), (46, 11)), fill=NOIR)
        d.rectangle(P((47, 9), (50, 12)), fill=NOIR)
    elif pose == "tip":
        d.polygon(P((9, 23), (13, 25), (11, 47), (7, 46)), fill=NOIR)
        d.polygon(P((29, 23), (33, 25), (37, 35), (34, 37)), fill=NOIR)
        d.polygon(P((34, 37), (37, 35), (32, 11), (29, 12)), fill=NOIR)
        d.rectangle(P((28, 8), (32, 12)), fill=NOIR)
    if eyes:
        d.rectangle(P((16, 15), (17, 15)), fill=EYE_G)
        d.rectangle(P((22, 15), (23, 15)), fill=EYE_G)
    return im


@lru_cache(maxsize=None)
def garrett_img(k=2, pose="stand", flap=0, eyes=True, rim_col=(255, 110, 50), rim_dir=1, rim2=None, flip=False, rim2_dir=None):
    im = garrett_base(pose, flap, eyes)
    if rim_col:
        im = rim(im, rim_col, dx=rim_dir)
    if rim2:
        dx2, dy2 = rim2_dir or (-rim_dir, -1)
        im = rim(im, rim2, dx=dx2, dy=dy2)
    if eyes:  # the rim pass may have painted over the eyes
        d = ImageDraw.Draw(im)
        d.rectangle((16 + GOX, 15 + GOY, 17 + GOX, 15 + GOY), fill=EYE_G)
        d.rectangle((22 + GOX, 15 + GOY, 23 + GOX, 15 + GOY), fill=EYE_G)
    im = scaled(im, k)
    return im.transpose(Image.FLIP_LEFT_RIGHT) if flip else im


def garrett(img, x, y, k=2, pose="stand", t=0.0, eyes=True, rim_col=(255, 110, 50), rim_dir=1, rim2=None, glow=1.0, flip=False, rim2_dir=None):
    """Agent Garrett standing with his feet at (x, y)."""
    flap = int(round(2.4 * math.sin(t * 4.2) + 0.6 * math.sin(t * 11)))
    spr = garrett_img(k, pose, flap, eyes, rim_col, rim_dir, rim2, flip, rim2_dir)
    x0 = int(round(x - spr.width / 2))
    y0 = int(round(y - (80 + GOY) * k))
    img.paste(spr, (x0, y0), spr)
    if eyes and glow > 0:
        for ex in (16.5, 22.5):
            exx = (64 - ex - GOX - 1) if flip else (ex + GOX)
            put(img, glow_img(max(3, int(4 * k * glow)), EYE_G, 0.55), x0 + exx * k, y0 + (15 + GOY) * k, anchor="center")


@lru_cache(maxsize=None)
def garrett_face(k=6, eyes=True, rim_col=None):
    """Hat, eyes and collar: the top of the figure, for close-ups and the radio window."""
    im = garrett_base("stand", 0, eyes)
    if rim_col:
        im = rim(im, rim_col, dx=1)
        d = ImageDraw.Draw(im)
        d.rectangle((16 + GOX, 15 + GOY, 17 + GOX, 15 + GOY), fill=EYE_G)
        d.rectangle((22 + GOX, 15 + GOY, 23 + GOX, 15 + GOY), fill=EYE_G)
    im = im.crop((GOX + 0, GOY - 1, GOX + 40, GOY + 34))
    return scaled(im, k)


# ----------------------------------------------------------------------------------------------- the bots

BOX, BOY = 7, 5  # bot frame (24x34) inside its padded 38x39 canvas


@lru_cache(maxsize=None)
def bot_base(pose="stand", step=0, eye="red", look=0, glasses=False, beard=1.0, mod=False, talk=False, angry=True, cute=False):
    """A comment-section bot: a boxy chrome head with one red eye, an antenna, an upvote on its chest and a
    beard of tangled cables. 24x34, feet on the bottom row."""
    im = Image.new("RGBA", (38, 39), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def P(*pts):
        return [(px + BOX, py + BOY) for px, py in pts]

    lf, rf = (1 if step == 1 else 0), (1 if step == 2 else 0)
    d.rectangle(P((5, 31 - lf), (10, 33 - lf)), fill=BOT_OUT)
    d.rectangle(P((14, 31 - rf), (19, 33 - rf)), fill=BOT_OUT)
    d.rectangle(P((7, 26), (8, 31 - lf)), fill=METAL_D)
    d.rectangle(P((16, 26), (17, 31 - rf)), fill=METAL_D)
    # arms behind the body for some poses
    arm = dict(fill=METAL_D, width=2)
    if pose == "hammer":
        d.line(P((5, 17), (9, 6)), **arm)
        d.line(P((19, 17), (15, 6)), **arm)
    # torso
    d.rounded_rectangle(P((4, 15), (20, 27)), radius=3, fill=METAL, outline=BOT_OUT)
    d.rectangle(P((17, 17), (19, 25)), fill=METAL_D)
    d.line(P((5, 18), (5, 24)), fill=METAL_L)
    if mod:
        d.polygon(P((10, 18), (14, 18), (14, 21), (12, 23), (10, 21)), fill=(60, 210, 100), outline=(20, 90, 40))
    else:
        d.polygon(P((12, 17), (15, 20), (13, 20), (13, 23), (11, 23), (11, 20), (9, 20)), fill=ORANGE)
    # arms in front
    if pose == "stand":
        d.line(P((4, 17), (1, 24)), **arm)
        d.line(P((20, 17), (23, 24)), **arm)
        d.point(P((0, 25), (2, 25), (22, 25), (24, 25)), fill=BOT_OUT)
    elif pose == "point":
        d.line(P((4, 17), (1, 24)), **arm)
        d.line(P((20, 18), (28, 18)), **arm)
        d.rectangle(P((28, 17), (30, 19)), fill=BOT_OUT)
    elif pose == "finger":
        d.line(P((4, 17), (1, 24)), **arm)
        d.line(P((20, 18), (25, 12)), **arm)
        d.rectangle(P((24, 11), (26, 13)), fill=METAL_D)
        d.line(P((25, 7), (25, 10)), fill=METAL_L)
    elif pose == "up":
        d.line(P((4, 17), (0, 9)), **arm)
        d.line(P((20, 17), (24, 9)), **arm)
    elif pose == "type":
        d.line(P((4, 17), (6, 23)), **arm)
        d.line(P((20, 17), (18, 23)), **arm)
        d.rectangle(P((2, 23), (22, 26)), fill=(40, 40, 54), outline=(14, 14, 20))
        for kx in range(4, 21, 3):
            d.point(P((kx, 24)), fill=(150, 160, 190))
    # head
    d.rounded_rectangle(P((3, 3), (21, 14)), radius=3, fill=METAL, outline=BOT_OUT)
    d.line(P((6, 4), (18, 4)), fill=METAL_L)
    d.rectangle(P((19, 6), (20, 12)), fill=METAL_D)
    d.rectangle(P((5, 6), (19, 10)), fill=(22, 18, 30))
    ex = 11 + look * 3
    if eye == "dead":
        for cx in (8, 16):
            d.line(P((cx - 1, 7), (cx + 1, 9)), fill=(150, 150, 170))
            d.line(P((cx - 1, 9), (cx + 1, 7)), fill=(150, 150, 170))
    elif eye == "heart":
        for cx in (8, 15):
            d.point(P((cx, 7), (cx + 2, 7)), fill=(255, 90, 140))
            d.line(P((cx, 8), (cx + 2, 8)), fill=(255, 90, 140))
            d.point(P((cx + 1, 9)), fill=(255, 90, 140))
    elif eye == "gold":
        for cx in (8, 16):
            d.line(P((cx - 1, 8), (cx + 1, 8)), fill=GOLD)
            d.line(P((cx, 7), (cx, 9)), fill=GOLD)
    elif eye == "off":
        d.rectangle(P((ex, 7), (ex + 1, 8)), fill=(70, 30, 34))
    else:
        col = {"red": (255, 50, 60), "blue": (90, 210, 255)}.get(eye, (255, 50, 60))
        d.rectangle(P((ex, 7), (ex + 1, 8)), fill=col)
        d.point(P((ex, 7)), fill=(255, 220, 220) if eye == "red" else (230, 250, 255))
        if cute:
            d.point(P((ex - 4, 7), (ex - 3, 8)), fill=col)
    if angry and eye in ("red",) and not cute:
        d.line(P((6, 5), (10, 6)), fill=BOT_OUT)
        d.line(P((18, 5), (14, 6)), fill=BOT_OUT)
    if talk:
        d.rectangle(P((9, 11), (15, 13)), fill=(22, 18, 30))
    elif cute:
        d.point(P((10, 12), (14, 12)), fill=(22, 18, 30))
        d.line(P((11, 13), (13, 13)), fill=(22, 18, 30))
    else:
        for gx in (9, 11, 13, 15):
            d.point(P((gx, 12)), fill=BOT_OUT)
    d.line(P((12, 0), (12, 3)), fill=BOT_OUT)
    d.rectangle(P((11, -2), (13, 0)), fill=ORANGE)
    if glasses:
        gc = (232, 238, 252)
        d.rectangle(P((5, 5), (10, 10)), outline=gc)
        d.rectangle(P((14, 5), (19, 10)), outline=gc)
        d.line(P((10, 7), (14, 7)), fill=gc)
        d.point(P((6, 6), (15, 6)), fill=(255, 255, 255))
    if beard > 0:
        rnd = random.Random(4)
        cols = [(34, 34, 46)] * 5 + [(200, 60, 60), (80, 120, 230), (230, 200, 60)]
        for i in range(10):
            x = 6 + i * 1.3
            ln = (2 + (i * 7) % 5) * beard
            c = cols[(i * 3) % len(cols)]
            pts = [(x, 14)]
            yy = 14
            while yy < 14 + ln:
                yy += 1
                pts.append((x + (1 if (yy + i) % 2 else -1) * (0.6 + rnd.random() * 0.6), yy))
            d.line(P(*pts), fill=c)
    return im


@lru_cache(maxsize=None)
def bot_img(k=2, flip=False, angle=0, tint=None, **kw):
    im = bot_base(**kw)
    if tint:
        im = tinted(im, tint, 0.85)
    im = scaled(im, k)
    if flip:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if angle:
        im = im.rotate(angle, resample=Image.NEAREST, expand=True)
    return im


def bot(img, x, y, k=2, walk_t=None, bob=0, anchor="bottom", flip=False, angle=0, tint=None, sq=None, **kw):
    """A bot with its feet at (x, y) (or centred there, for one flying through the air)."""
    if walk_t is not None:
        ph = int(walk_t * 8) % 4
        kw["step"] = (0, 1, 0, 2)[ph]
        bob += 1 if ph in (1, 3) else 0
    spr = bot_img(k, flip, angle, tint, **kw)
    if sq:
        spr = squashed(spr, *sq)
    if anchor == "bottom":
        put(img, spr, x, y - bob * k)
    else:
        put(img, spr, x, y, anchor="center")


def banhammer(img, x, y, ang, k=2):
    """The mod's hammer, its handle end at (x, y), pointing at `ang` degrees (0 = straight up)."""
    im = _hammer(k)
    r = im.rotate(-ang, resample=Image.NEAREST, expand=True)
    L = 22 * k
    cx = x + math.sin(math.radians(ang)) * L
    cy = y - math.cos(math.radians(ang)) * L
    put(img, r, cx, cy, anchor="center")


@lru_cache(maxsize=None)
def _hammer(k):
    im = Image.new("RGBA", (36, 60), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # centred on the canvas; the handle runs down from the head to the canvas bottom
    d.rectangle((16, 16, 19, 59), fill=(120, 80, 40), outline=(60, 36, 16))
    d.rectangle((2, 2, 33, 20), fill=(70, 74, 90), outline=(20, 20, 28))
    d.rectangle((2, 2, 33, 5), fill=(130, 136, 156))
    d.rectangle((4, 7, 31, 17), fill=(60, 210, 100))
    gfx.draw(im).text((18, 12), "BAN", font=pix(9), fill=(10, 40, 20), anchor="mm")
    return scaled(im, k)


def gold_award(img, x, y, t, r=7):
    d = ImageDraw.Draw(img)
    put(img, glow_img(int(r * 2.4), (255, 220, 90), 0.6), x, y, anchor="center")
    w = abs(math.cos(t * 9)) * r + 1
    d.ellipse((x - w, y - r, x + w, y + r), fill=GOLD, outline=GOLD_D)
    if w > 3:
        d.ellipse((x - w + 2, y - r + 2, x + w - 2, y + r - 2), outline=(255, 240, 160))
        d.point((x, y), fill=(255, 255, 230))
        d.line((x - 1, y - 2, x + 1, y + 2), fill=(255, 250, 200))


# ----------------------------------------------------------------------------------------------- the boss

BOSS_SKIN = (176, 182, 202)


@lru_cache(maxsize=None)
def boss_base(pose="finger", eye="red", melt=0.0, glasses_off=False):
    """ACKSHUALLY-9000: a heavy bot in a gaming chair, headset on, glasses, an energy drink, and a beard of
    cables down to its belly. 84x92."""
    im = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    ox, oy = 6, 2

    def P(*pts):
        return [(px + ox, py + oy) for px, py in pts]

    sag = int(6 * melt)
    # the chair: tall back with wings, red stripes, seat, armrests, a stem down to the hover jets
    d.rounded_rectangle(P((14, 0), (70, 66)), radius=8, fill=(28, 24, 34), outline=(10, 8, 14))
    d.polygon(P((14, 6), (6, 2), (8, 22), (14, 26)), fill=(28, 24, 34), outline=(10, 8, 14))
    d.polygon(P((70, 6), (78, 2), (76, 22), (70, 26)), fill=(28, 24, 34), outline=(10, 8, 14))
    d.rectangle(P((20, 4), (24, 60)), fill=(200, 36, 50))
    d.rectangle(P((60, 4), (64, 60)), fill=(200, 36, 50))
    d.rounded_rectangle(P((8, 62), (76, 72)), radius=3, fill=(36, 30, 42), outline=(10, 8, 14))
    d.rectangle(P((6, 52), (16, 58)), fill=(36, 30, 42), outline=(10, 8, 14))
    d.rectangle(P((68, 52), (78, 58)), fill=(36, 30, 42), outline=(10, 8, 14))
    d.rectangle(P((38, 72), (46, 82)), fill=(60, 60, 72), outline=(20, 20, 28))
    d.rectangle(P((22, 80), (62, 84)), fill=(60, 60, 72), outline=(20, 20, 28))
    for jx in (24, 56):
        d.rectangle(P((jx - 4, 82), (jx + 4, 88)), fill=(80, 82, 96), outline=(20, 20, 28))
    # stubby legs over the seat edge
    d.rectangle(P((30, 66), (36, 76)), fill=METAL_D, outline=BOT_OUT)
    d.rectangle(P((48, 66), (54, 76)), fill=METAL_D, outline=BOT_OUT)
    # the body
    d.ellipse(P((18, 30 + sag), (66, 70)), fill=BOSS_SKIN, outline=BOT_OUT)
    d.chord(P((22, 34 + sag), (62, 68)), 300, 60, fill=METAL_D)
    d.rounded_rectangle(P((28, 46 + sag), (56, 60)), radius=2, fill=(18, 16, 26), outline=BOT_OUT)
    # arms
    arm = dict(fill=METAL_D, width=4)
    if pose == "finger":
        d.line(P((20, 44 + sag), (8, 52)), **arm)
        d.rectangle(P((2, 44), (10, 56)), fill=(60, 210, 100), outline=(20, 60, 30))  # the can
        d.rectangle(P((2, 48), (10, 51)), fill=(20, 20, 24))
        d.line(P((64, 44 + sag), (78, 30)), **arm)
        d.rectangle(P((75, 26), (81, 32)), fill=METAL, outline=BOT_OUT)
        d.line(P((79, 18), (79, 25)), fill=METAL_L, width=2)
    elif pose == "beam":
        d.line(P((20, 44 + sag), (4, 34)), **arm)
        d.line(P((64, 44 + sag), (80, 34)), **arm)
        d.rectangle(P((0, 30), (6, 36)), fill=METAL, outline=BOT_OUT)
        d.rectangle(P((78, 30), (84, 36)), fill=METAL, outline=BOT_OUT)
    elif pose == "touch":
        d.line(P((20, 44 + sag), (10, 60)), **arm)
        d.line(P((64, 44 + sag), (74, 84)), **arm)
        d.rectangle(P((70, 84), (78, 90)), fill=METAL, outline=BOT_OUT)
    else:  # "slump"
        d.line(P((20, 44 + sag), (12, 66)), **arm)
        d.line(P((64, 44 + sag), (72, 66)), **arm)
    # the head
    hy = 4 + sag
    d.rounded_rectangle(P((24, hy + 4), (60, hy + 32)), radius=5, fill=BOSS_SKIN, outline=BOT_OUT)
    d.line(P((28, hy + 6), (56, hy + 6)), fill=METAL_L)
    # headset: band over the top, ear cups, a mic boom
    d.arc(P((20, hy - 2), (64, hy + 26)), 190, 350, fill=(30, 30, 38), width=3)
    d.rounded_rectangle(P((18, hy + 12), (25, hy + 24)), radius=2, fill=(30, 30, 38))
    d.rounded_rectangle(P((59, hy + 12), (66, hy + 24)), radius=2, fill=(30, 30, 38))
    d.line(P((22, hy + 24), (32, hy + 30)), fill=(30, 30, 38), width=2)
    d.rectangle(P((32, hy + 29), (35, hy + 31)), fill=(200, 40, 50))
    # visor and eye
    d.rectangle(P((28, hy + 11), (56, hy + 21)), fill=(18, 14, 24))
    ecol = {"red": (255, 50, 60), "hot": (255, 200, 200), "off": (70, 30, 34), "green": (120, 255, 140)}.get(eye, (255, 50, 60))
    d.rectangle(P((35, hy + 14), (38, hy + 17)), fill=ecol)
    if eye != "off":
        d.point(P((35, hy + 14)), fill=(255, 230, 230))
    if not glasses_off:
        gc = (232, 238, 252)
        tilt = int(3 * melt)
        d.rounded_rectangle(P((27, hy + 10 + tilt), (40, hy + 21 + tilt)), radius=2, outline=gc)
        d.rounded_rectangle(P((44, hy + 10), (57, hy + 21)), radius=2, outline=gc)
        d.line(P((40, hy + 14 + tilt), (44, hy + 14)), fill=gc)
        d.line(P((29, hy + 12 + tilt), (31, hy + 12 + tilt)), fill=(255, 255, 255))
        d.line(P((46, hy + 12), (48, hy + 12)), fill=(255, 255, 255))
        d.point(P((29, hy + 13 + tilt), (46, hy + 13)), fill=(180, 200, 230))
    # antenna
    d.line(P((42, hy + 4), (42, hy - 4)), fill=BOT_OUT, width=2)
    d.ellipse(P((39, hy - 8), (45, hy - 2)), fill=ORANGE, outline=(120, 30, 0))
    # the beard of cables
    rnd = random.Random(9)
    cols = [(34, 34, 46)] * 6 + [(200, 60, 60), (80, 120, 230), (230, 200, 60), (90, 200, 90)]
    for i in range(22):
        x = 30 + i * 1.15
        ln = (6 + (i * 7) % 9) * (1 - 0.4 * melt)
        c = cols[(i * 5) % len(cols)]
        if melt > 0.5 and i % 3 == 0:
            c = GRASS
        pts, yy = [(x, hy + 30)], hy + 30
        while yy < hy + 30 + ln:
            yy += 1.5
            pts.append((x + (1 if int(yy + i) % 2 else -1) * (0.5 + rnd.random()), yy))
        d.line(P(*pts), fill=c)
    return im


@lru_cache(maxsize=None)
def boss_img(k=2, tint=None, **kw):
    im = boss_base(**kw)
    if tint:
        im = tinted(im, tint, 0.8)
    return scaled(im, k)


def boss(img, x, y, t, k=2, jets=True, tint=None, **kw):
    """The boss centred at (x, y), bobbing on its chair jets."""
    spr = boss_img(k, tint, **kw)
    by = y + 3 * math.sin(t * 2.2)
    x0, y0 = int(x - spr.width / 2), int(by - spr.height / 2)
    if jets:
        d = ImageDraw.Draw(img)
        for jx in (24, 56):
            bx = x0 + (jx + 6) * k
            by0 = y0 + 90 * k
            fl = (9 + 4 * abs(math.sin(t * 25 + jx))) * k
            d.polygon(((bx - 4 * k, by0), (bx + 4 * k, by0), (bx, by0 + fl)), fill=(255, 140, 40))
            d.polygon(((bx - 2 * k, by0), (bx + 2 * k, by0), (bx, by0 + fl * 0.6)), fill=(255, 240, 170))
    img.paste(spr, (x0, y0), spr)
    return x0, y0


def boss_eye(x0, y0, k=2, melt=0.0):
    """Screen position of the boss's eye, from the corner `boss()` returned."""
    sag = int(6 * melt)
    return x0 + (6 + 36.5) * k, y0 + (2 + 4 + sag + 15.5) * k


# ----------------------------------------------------------------------------------------------- tots in gear

@lru_cache(maxsize=None)
def gtot_base(gear=(), brows=False, yell=False, **kw):
    """A tot from the trailer (gfx.tot_base) dressed for war: helmet, headband, a fork. 30x30 with the tot's
    feet still on the bottom row."""
    base = tot_base(**kw)
    im = Image.new("RGBA", (30, 30), (0, 0, 0, 0))
    im.paste(base, (4, 4), base)
    d = ImageDraw.Draw(im)

    def P(*pts):
        return [(px + 4, py + 4) for px, py in pts]

    if brows:
        d.line(P((6, 10), (8, 11)), fill=OUT)
        d.line(P((15, 10), (13, 11)), fill=OUT)
    if yell:
        d.rectangle(P((9, 15), (12, 17)), fill=(120, 30, 40))
        d.line(P((9, 15), (12, 15)), fill=(255, 255, 255))
    if "helmet" in gear:
        d.chord(P((3, 1), (18, 15)), 180, 360, fill=(104, 122, 62), outline=(56, 70, 32))
        d.line(P((2, 8), (19, 8)), fill=(56, 70, 32))
        d.point(P((7, 3), (8, 3)), fill=(150, 168, 100))
    if "band" in gear:
        d.line(P((4, 9), (17, 9)), fill=(220, 40, 44))
        d.line(P((4, 10), (17, 10)), fill=(170, 20, 30))
        d.line(P((17, 9), (21, 11)), fill=(220, 40, 44))
        d.line(P((17, 10), (20, 13)), fill=(170, 20, 30))
    if "fork" in gear:
        arms = kw.get("arms", "down")
        sv, sd = (226, 230, 240), (120, 126, 146)
        if arms in ("up", "wave"):
            d.line(P((21, 9), (21, 2)), fill=sv)
            d.line(P((20, 2), (22, 2)), fill=sv)
            for tx in (20, 21, 22):
                d.line(P((tx, -2), (tx, 1)), fill=sv)
            d.point(P((22, 3)), fill=sd)
        elif arms == "point":
            d.line(P((21, 13), (23, 13)), fill=sv)
            d.line(P((23, 12), (23, 14)), fill=sv)
            for ty in (12, 13, 14):
                d.line(P((24, ty), (25, ty)), fill=sv)
        else:
            d.line(P((20, 19), (20, 12)), fill=sv)
            d.line(P((19, 12), (21, 12)), fill=sv)
            for tx in (19, 20, 21):
                d.line(P((tx, 9), (tx, 11)), fill=sv)
    if "ketchup" in gear:
        d.rectangle(P((19, 15), (22, 21)), fill=(214, 30, 30), outline=(110, 10, 10))
        d.rectangle(P((20, 13), (21, 14)), fill=(240, 240, 240))
    return im


@lru_cache(maxsize=None)
def gtot_img(k=2, flip=False, angle=0, tint=None, gear=(), brows=False, yell=False, **kw):
    im = gtot_base(gear, brows, yell, **kw)
    if tint:
        im = tinted(im, tint, 0.85)
    im = scaled(im, k)
    if flip:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if angle:
        im = im.rotate(angle, resample=Image.NEAREST, expand=True)
    return im


def gtot(img, x, y, k=2, glow=False, walk_t=None, bob=0, anchor="bottom", sq=None, **kw):
    """A (geared) tot with its feet at (x, y), or centred there with anchor='center'."""
    if walk_t is not None:
        ph = int(walk_t * 8) % 4
        kw["step"] = (0, 1, 0, 2)[ph]
        bob += 1 if ph in (1, 3) else 0
    if glow:
        put(img, glow_img(int(14 * k)), x, y - 12 * k, anchor="center")
    spr = gtot_img(k, **kw)
    if sq:
        spr = squashed(spr, *sq)
    if anchor == "bottom":
        put(img, spr, x, y - bob * k)
    else:
        put(img, spr, x, y, anchor="center")


# ----------------------------------------------------------------------------------------------- people

SKINS = ((240, 200, 164), (196, 140, 100), (140, 96, 64), (232, 186, 150))


@lru_cache(maxsize=None)
def human_base(shirt=(60, 120, 220), hair=(60, 40, 30), skin=0, coat=False, glasses=False, pose="stand", step=0):
    """A small person, 12x20, feet on the bottom row."""
    im = Image.new("RGBA", (16, 20), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    sk = SKINS[skin % len(SKINS)]
    pants = (50, 50, 70)
    if pose == "run":
        a, b = (2, -2) if step % 2 else (-2, 2)
        d.line((7, 14, 7 + a, 19), fill=pants)
        d.line((9, 14, 9 + b, 19), fill=pants)
    else:
        d.line((7, 14, 7, 19), fill=pants)
        d.line((9, 14, 9, 19), fill=pants)
    body = (236, 240, 246) if coat else shirt
    d.rectangle((6, 8, 10, 14), fill=body)
    if coat:
        d.rectangle((6, 14, 10, 16), fill=body)
        d.line((8, 8, 8, 16), fill=(180, 186, 200))
        d.point((7, 9), fill=shirt)
    if pose in ("run", "scared"):
        d.line((6, 9, 3, 5), fill=body)
        d.line((10, 9, 13, 5), fill=body)
        d.point(((3, 4), (13, 4)), fill=sk)
    elif pose == "clip":
        d.line((6, 9, 5, 13), fill=body)
        d.line((10, 9, 12, 11), fill=body)
        d.rectangle((11, 9, 14, 13), fill=(200, 160, 100), outline=(120, 90, 50))
    else:
        d.line((6, 9, 5, 13), fill=body)
        d.line((10, 9, 11, 13), fill=body)
    d.rectangle((6, 2, 10, 7), fill=sk)
    d.rectangle((6, 1, 10, 2), fill=hair)
    d.point((6, 3), fill=hair)
    d.point(((7, 4), (9, 4)), fill=(20, 16, 20))
    if glasses:
        d.line((6, 4, 10, 4), fill=(240, 240, 255))
        d.point(((7, 4), (9, 4)), fill=(30, 30, 40))
    if pose in ("run", "scared"):
        d.point((8, 6), fill=(80, 20, 30))
    return im


def human(img, x, y, k=2, walk_t=None, sq=None, flip=False, **kw):
    if walk_t is not None:
        kw["pose"] = "run"
        kw["step"] = int(walk_t * 12) % 2
    spr = scaled(human_base(**kw), k)
    if flip:
        spr = spr.transpose(Image.FLIP_LEFT_RIGHT)
    if sq:
        spr = squashed(spr, *sq)
    put(img, spr, x, y)


# ----------------------------------------------------------------------------------------------- backgrounds

def skyline(d, base, rnd, col, hmin, hmax, wmin=14, wmax=30, lit=None, broken=True):
    x = -6
    while x < W:
        w = rnd.randrange(wmin, wmax)
        h = rnd.randrange(hmin, hmax)
        top = base - h
        d.rectangle((x, top, x + w, base), fill=col)
        if broken and rnd.random() < 0.6:
            d.polygon(((x, top), (x + w * 0.3, top - rnd.randrange(3, 9)), (x + w * 0.55, top + 2), (x + w * 0.8, top - 4), (x + w, top)), fill=col)
        if rnd.random() < 0.25:
            d.line((x + w // 2, top, x + w // 2, top - rnd.randrange(8, 20)), fill=col)
        if lit:
            for wy in range(top + 5, base - 4, 6):
                for wx in range(x + 3, x + w - 2, 5):
                    if rnd.random() < 0.18:
                        d.rectangle((wx, wy, wx + 1, wy + 2), fill=lit)
        x += w + rnd.randrange(0, 5)


@lru_cache(maxsize=None)
def bg_battle(mood="orange"):
    """The ruined city under an orange-red sky (the colour of an upvote, which is the point)."""
    img = canvas()
    if mood == "orange":
        stops = ((0, (34, 6, 16)), (0.4, (122, 22, 14)), (0.72, (232, 70, 14)), (1, (255, 150, 60)))
        far, mid, near = (150, 40, 30), (86, 18, 24), (44, 10, 20)
        sun = (255, 196, 120)
    else:  # the boss storm
        stops = ((0, (14, 6, 28)), (0.5, (58, 16, 70)), (1, (150, 40, 80)))
        far, mid, near = (70, 24, 70), (44, 14, 50), (26, 8, 32)
        sun = None
    img.paste(grad_img(stops, GROUND), (0, 0))
    d = ImageDraw.Draw(img)
    if sun:
        put(img, glow_img(96, (255, 170, 90), 0.45), 150, 252, anchor="center")
        d.ellipse((96, 200, 204, 308), fill=sun)
        for i, yy in enumerate(range(236, 300, 9)):
            d.rectangle((90, yy, 210, yy + 1 + i // 2), fill=mix(stops[2][1], stops[3][1], 0.6))
    rnd = random.Random(21)
    skyline(d, 318, rnd, far, 40, 120, lit=None)
    skyline(d, 336, rnd, mid, 30, 90, lit=(255, 150, 60))
    skyline(d, 352, rnd, near, 20, 56, 20, 40, lit=(255, 190, 90))
    # the street
    gtop = (60, 40, 46) if mood == "orange" else (40, 28, 50)
    img.paste(grad_img(((0, gtop), (1, mix(gtop, (0, 0, 0), 0.55))), H - GROUND, 6), (0, GROUND))
    d.line((0, GROUND, W, GROUND), fill=mix(gtop, (255, 160, 120), 0.35))
    for xx in range(-400, W + 400, 34):
        d.line((W / 2 + (xx - W / 2) * 0.25, GROUND, xx, H), fill=mix(gtop, (0, 0, 0), 0.2))
    rnd = random.Random(3)
    for _ in range(18):
        x, y = rnd.randrange(W), rnd.randrange(GROUND + 6, H)
        r = rnd.randrange(2, 6)
        d.ellipse((x - r, y - r // 2, x + r, y + r // 2), fill=mix(gtop, (0, 0, 0), 0.4))
        d.point((x - r // 2, y - r // 2), fill=mix(gtop, (255, 255, 255), 0.2))
    for _ in range(5):  # cracks
        x, y = rnd.randrange(W), rnd.randrange(GROUND + 10, H - 10)
        pts = [(x, y)]
        for _ in range(4):
            x += rnd.randrange(-10, 11)
            y += rnd.randrange(2, 9)
            pts.append((x, y))
        d.line(pts, fill=mix(gtop, (0, 0, 0), 0.6))
    return img


def battle(t, mood="orange", fires=True):
    img = bg_battle(mood).copy()
    for i, (x, y, s) in enumerate(((30, 338, 1.4), (120, 350, 1.0), (230, 342, 1.6))):
        smoke(img, t, x, y, s, seed=i + 2, col=(36, 22, 30) if mood == "orange" else (30, 20, 40), a=0.55)
    if fires:
        for i, (x, y, s) in enumerate(((22, 352, 0.9), (196, 354, 0.7), (250, 350, 1.0))):
            fire(img, x, y, t, s, seed=i)
    embers(img, t, 30, y0=60, y1=GROUND)
    return img


@lru_cache(maxsize=None)
def bg_lab():
    img = canvas()
    img.paste(grad_img(((0, (14, 18, 34)), (1, (34, 44, 74))), GROUND, 8), (0, 0))
    d = ImageDraw.Draw(img)
    for x in range(0, W, 45):
        d.line((x, 0, x, GROUND), fill=(22, 28, 50))
    d.rectangle((0, 140, W, 143), fill=(24, 30, 52))
    # floor tiles toward a vanishing point
    img.paste(grad_img(((0, (44, 52, 82)), (1, (22, 26, 44))), H - GROUND, 6), (0, GROUND))
    for xx in range(-600, W + 600, 30):
        d.line((W / 2 + (xx - W / 2) * 0.2, GROUND, xx, H), fill=(30, 36, 60))
    for yy in (372, 390, 416, 450):
        d.line((0, yy, W, yy), fill=(30, 36, 60))
    d.line((0, GROUND, W, GROUND), fill=(80, 96, 140))
    # server racks
    for x0 in (6, 222):
        d.rectangle((x0, 168, x0 + 42, GROUND), fill=(26, 30, 46), outline=(60, 70, 100))
        for yy in range(176, GROUND - 6, 12):
            d.rectangle((x0 + 4, yy, x0 + 38, yy + 8), fill=(36, 42, 62))
    # the monitor
    d.rectangle((26, 30, 244, 136), fill=(40, 44, 60), outline=(90, 100, 130))
    d.rectangle((32, 36, 238, 130), fill=(8, 22, 30))
    # the feed pipe and hopper over the pedestal
    d.rectangle((124, 0, 146, 150), fill=(70, 78, 104), outline=(30, 34, 50))
    d.line((128, 0, 128, 150), fill=(110, 120, 150))
    d.polygon(((98, 150), (172, 150), (152, 196), (118, 196)), fill=(80, 88, 116), outline=(30, 34, 50))
    d.line((100, 152, 170, 152), fill=(130, 140, 170))
    # pedestal
    d.rectangle((94, 330, 176, GROUND + 4), fill=(60, 66, 92), outline=(24, 28, 40))
    d.rectangle((90, 326, 180, 332), fill=(90, 220, 255))
    d.rectangle((90, 332, 180, 333), fill=(40, 120, 160))
    return img


def lab(t, alarm=0.0):
    img = bg_lab().copy()
    d = ImageDraw.Draw(img)
    rnd = random.Random(int(t * 6))
    for x0 in (6, 222):
        for yy in range(176, GROUND - 6, 12):
            for j in range(3):
                on = rnd.random() < 0.6
                c = (255, 60, 70) if alarm > 0 and on else ((90, 255, 140) if on else (30, 60, 40))
                d.point((x0 + 30 + j * 3, yy + 4), fill=c)
    if alarm > 0:
        a = alarm * (0.5 + 0.5 * math.sin(t * 18))
        flash(img, 0.28 * a, (255, 0, 20))
        for x in (40, 230):
            put(img, glow_img(30, (255, 40, 50), 0.6 * a), x, 12, anchor="center")
            d.ellipse((x - 6, 6, x + 6, 18), fill=(255, 60, 70) if a > 0.5 else (140, 20, 30))
    return img


@lru_cache(maxsize=None)
def bg_rooftop():
    img = canvas()
    img.paste(grad_img(((0, (4, 4, 14)), (0.55, (22, 14, 40)), (0.85, (90, 30, 44)), (1, (190, 70, 40))), 400, 12), (0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(2)
    for _ in range(60):
        d.point((rnd.randrange(W), rnd.randrange(200)), fill=(200, 200, 230) if rnd.random() < 0.7 else (255, 255, 255))
    # the moon
    put(img, glow_img(70, (200, 200, 255), 0.35), 196, 96, anchor="center")
    d.ellipse((162, 62, 230, 130), fill=(232, 228, 214))
    for cx, cy, r in ((180, 84, 7), (206, 104, 9), (192, 116, 4), (214, 78, 4)):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(206, 200, 186))
    # the burning city far below
    skyline(d, 392, random.Random(11), (40, 16, 30), 30, 110, 12, 26, lit=(255, 150, 60))
    skyline(d, 402, random.Random(12), (24, 10, 20), 14, 60, 18, 34, lit=(255, 200, 100))
    # water tower and an antenna on the roof
    d.rectangle((24, 250, 70, 312), fill=(10, 8, 16))
    d.polygon(((20, 250), (47, 226), (74, 250)), fill=(10, 8, 16))
    for lx in (28, 46, 64):
        d.line((lx, 312, lx + (lx - 46) // 4, 402), fill=(10, 8, 16), width=2)
    d.line((26, 340, 68, 370), fill=(10, 8, 16))
    d.line((68, 340, 26, 370), fill=(10, 8, 16))
    d.line((246, 402, 246, 300), fill=(10, 8, 16), width=2)
    d.line((238, 320, 254, 320), fill=(10, 8, 16))
    d.line((240, 336, 252, 336), fill=(10, 8, 16))
    # the ledge
    d.rectangle((0, 402, W, H), fill=(14, 12, 22))
    d.rectangle((0, 402, W, 406), fill=(30, 26, 44))
    d.line((0, 402, W, 402), fill=(120, 60, 60))
    return img


@lru_cache(maxsize=None)
def bg_meadow():
    img = canvas()
    img.paste(grad_img(((0, (70, 140, 240)), (0.7, (150, 210, 255)), (1, (255, 226, 170))), GROUND, 10), (0, 0))
    d = ImageDraw.Draw(img)
    put(img, glow_img(80, (255, 240, 170), 0.5), 200, 120, anchor="center")
    d.ellipse((176, 96, 224, 144), fill=(255, 244, 190))
    for x, y, s in ((20, 70, 1.2), (110, 40, 0.9), (60, 190, 1.0), (190, 220, 1.3)):
        gfx.cloud(d, x, y, s)
    for base, amp, freq, ph, col in ((300, 16, 0.03, 0.5, (124, 200, 100)), (330, 12, 0.045, 2.0, (96, 178, 80))):
        pts = [(x, base - amp * math.sin(x * freq + ph)) for x in range(0, W + 6, 6)]
        d.polygon(pts + [(W, H), (0, H)], fill=col)
    d.rectangle((0, GROUND, W, H), fill=(82, 160, 66))
    d.line((0, GROUND, W, GROUND), fill=(130, 210, 100))
    rnd = random.Random(7)
    for _ in range(140):
        x, y = rnd.randrange(W), rnd.randrange(GROUND + 2, H)
        d.point((x, y), fill=(60, 130, 50))
    for _ in range(40):
        x, y = rnd.randrange(W), rnd.randrange(GROUND + 4, H - 4)
        d.point((x, y), fill=rnd.choice(((255, 240, 120), (255, 170, 200), (255, 255, 255), (180, 160, 255))))
        d.point((x, y + 1), fill=(50, 110, 44))
    return img


def storm_rays(img, t, cx=135, cy=150, col1=(60, 20, 90), col2=(34, 12, 60), a=1.0):
    lay = layer()
    d = ImageDraw.Draw(lay)
    for i in range(22):
        ang = t * 0.8 + i * math.tau / 22
        c = col1 if i % 2 else col2
        d.polygon(((cx, cy), (cx + 700 * math.cos(ang), cy + 700 * math.sin(ang)), (cx + 700 * math.cos(ang + 0.14), cy + 700 * math.sin(ang + 0.14))),
                  fill=c + (int(255 * a),))
    img.alpha_composite(lay)


def sun_rays(img, t, cx, cy, col=(255, 236, 160), a=0.35, n=16):
    lay = layer()
    d = ImageDraw.Draw(lay)
    for i in range(n):
        ang = t * 0.35 + i * math.tau / n
        d.polygon(((cx, cy), (cx + 700 * math.cos(ang), cy + 700 * math.sin(ang)), (cx + 700 * math.cos(ang + 0.12), cy + 700 * math.sin(ang + 0.12))),
                  fill=col + (int(255 * a),))
    img.alpha_composite(lay)


def mothership(img, cx, cy, t, s=1.0):
    """A giant orange arrow hanging over the city, its belly lit, sweeping searchlights."""
    d = ImageDraw.Draw(img)
    for i in range(3):
        ang = math.pi / 2 + 0.5 * math.sin(t * 1.1 + i * 2.1)
        lay = layer()
        sx = cx + (i - 1) * 34 * s
        pts = [(sx, cy + 22 * s), (sx + 260 * math.cos(ang - 0.12), cy + 260 * math.sin(ang - 0.12)), (sx + 260 * math.cos(ang + 0.12), cy + 260 * math.sin(ang + 0.12))]
        ImageDraw.Draw(lay).polygon(pts, fill=(255, 220, 160, 46))
        img.alpha_composite(lay)
    pts = [(cx, cy - 46 * s), (cx + 62 * s, cy + 8 * s), (cx + 26 * s, cy + 8 * s), (cx + 26 * s, cy + 30 * s), (cx - 26 * s, cy + 30 * s), (cx - 26 * s, cy + 8 * s), (cx - 62 * s, cy + 8 * s)]
    d.polygon(pts, fill=(220, 60, 10), outline=(90, 20, 0))
    d.polygon([(cx, cy - 40 * s), (cx + 50 * s, cy + 4 * s), (cx - 50 * s, cy + 4 * s)], fill=(255, 96, 30))
    d.line((cx - 56 * s, cy + 8 * s, cx + 56 * s, cy + 8 * s), fill=(255, 170, 110))
    for i in range(7):
        lx = cx - 22 * s + i * 7.3 * s
        on = int(t * 6 + i) % 3 != 0
        d.rectangle((lx, cy + 22 * s, lx + 2 * s, cy + 24 * s), fill=(255, 240, 180) if on else (120, 40, 10))
    d.ellipse((cx - 5 * s, cy - 12 * s, cx + 5 * s, cy - 2 * s), fill=(255, 50, 60))


def grass_cover(img, front, t, y0=GROUND, flowers=True, seed=4):
    """Grass and flowers spreading over the street out to `front` px from the centre (both directions)."""
    if front <= 0:
        return
    d = ImageDraw.Draw(img)
    x0, x1 = max(0, 135 - front), min(W, 135 + front)
    d.rectangle((x0, y0, x1, H), fill=(82, 160, 66))
    d.line((x0, y0, x1, y0), fill=(130, 210, 100))
    rnd = random.Random(seed)
    for _ in range(320):
        x, y = rnd.randrange(W), rnd.randrange(y0 - 3, H)
        if x0 <= x <= x1:
            h = rnd.randrange(2, 6)
            d.line((x, y, x + rnd.choice((-1, 0, 1)), y - h), fill=GRASS if rnd.random() < 0.6 else GRASS_D)
    if flowers:
        for _ in range(70):
            x, y = rnd.randrange(W), rnd.randrange(y0 + 2, H)
            if x0 <= x <= x1:
                c = rnd.choice(((255, 240, 120), (255, 170, 200), (255, 255, 255), (190, 160, 255)))
                d.point((x, y), fill=c)
                d.point((x - 1, y), fill=c)
                d.point((x + 1, y), fill=c)
                d.point((x, y - 1), fill=c)
                d.point((x, y), fill=(255, 220, 80))
    # the edge of the wave: a ragged green front
    for edge in (x0, x1):
        if 0 < edge < W:
            for yy in range(y0, H, 3):
                d.line((edge, yy, edge + rnd.choice((-3, 3)), yy - 4), fill=GRASS)


def brawl_cloud(img, cx, cy, t, r=46, seed=1):
    """The cartoon fight: a churning dust cloud with fists, feet, stars and a forearm or two sticking out."""
    d = ImageDraw.Draw(img)
    rnd = random.Random(int(t * 14) + seed)
    for _ in range(4):  # limbs poking out
        a = rnd.random() * math.tau
        ex, ey = cx + math.cos(a) * r * 1.15, cy + math.sin(a) * r * 0.75
        if rnd.random() < 0.5:
            d.line((cx + math.cos(a) * r * 0.6, cy + math.sin(a) * r * 0.4, ex, ey), fill=gfx.OUT, width=2)
            d.ellipse((ex - 3, ey - 3, ex + 3, ey + 3), fill=gfx.BODY, outline=gfx.OUT)
        else:
            d.line((cx + math.cos(a) * r * 0.6, cy + math.sin(a) * r * 0.4, ex, ey), fill=METAL_D, width=3)
            d.rectangle((ex - 3, ey - 3, ex + 3, ey + 3), fill=METAL, outline=BOT_OUT)
    for i in range(14):
        a = i / 14 * math.tau + t * 3
        rr = r * (0.55 + 0.25 * rnd.random())
        x, y = cx + math.cos(a) * rr, cy + math.sin(a) * rr * 0.62
        s = 14 + rnd.randrange(10)
        d.ellipse((x - s, y - s * 0.8, x + s, y + s * 0.8), fill=(236, 226, 214), outline=(120, 100, 96))
    for i in range(6):
        x, y = cx + rnd.randrange(-r // 2, r // 2), cy + rnd.randrange(-r // 3, r // 3)
        s = 12 + rnd.randrange(8)
        d.ellipse((x - s, y - s * 0.8, x + s, y + s * 0.8), fill=(250, 244, 236))
    for _ in range(3):
        x, y = cx + rnd.randrange(-r, r), cy + rnd.randrange(-r // 2, r // 2)
        d.line((x - 3, y, x + 3, y), fill=(255, 220, 60))
        d.line((x, y - 3, x, y + 3), fill=(255, 220, 60))


def wall_of_text(img, x0, y0, w, h, seed=2):
    """A comment so long it is a building: a slab of tiny grey lines, a title, and a scrollbar."""
    d = ImageDraw.Draw(img)
    d.rectangle((x0, y0, x0 + w, y0 + h), fill=(30, 30, 34), outline=(90, 90, 100))
    d.rectangle((x0, y0, x0 + w, y0 + 14), fill=(46, 46, 52))
    label(img, (x0 + 4, y0 + 2), "well, actually...", 9, (255, 140, 120), stroke=0)
    rnd = random.Random(seed)
    y = y0 + 20
    while y < y0 + h - 4:
        x = x0 + 4
        while x < x0 + w - 12:
            ln = rnd.randrange(3, 14)
            if x + ln > x0 + w - 10:
                break
            d.line((x, y, x + ln, y), fill=(150, 150, 160) if rnd.random() < 0.9 else (255, 140, 100))
            x += ln + 2
        y += 4 if rnd.random() < 0.9 else 8
    d.rectangle((x0 + w - 6, y0 + 16, x0 + w - 3, y0 + h - 3), fill=(50, 50, 56))
    d.rectangle((x0 + w - 6, y0 + 16, x0 + w - 3, y0 + 22), fill=(130, 130, 140))
