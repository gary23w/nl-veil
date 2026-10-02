"""The product reveal, drawn at full 1920x1080 with smooth type: the desk's Tots tab in its Tokyo Night palette."""
import math

from PIL import Image, ImageDraw, ImageFont

import gfx
from gfx import seg, ease_out, ease_io, bounce, lerp, clamp01

FW, FH = 1920, 1080
F = "C:/Windows/Fonts/"


def hx(s):
    return tuple(int(s[i : i + 2], 16) for i in (0, 2, 4))


BG, BG_DARK, BG_HL, BG_SEL = hx("1a1b26"), hx("16161e"), hx("1f2335"), hx("283457")
FG, FG_DIM, COMMENT, BORDER = hx("e9edfa"), hx("a9b1d6"), hx("565f89"), hx("292e42")
BLUE, GREEN, RED, YELLOW, MAGENTA, ORANGE, CYAN = hx("7aa2f7"), hx("9ece6a"), hx("f7768e"), hx("e0af68"), hx("bb9af7"), hx("ff9e64"), hx("7dcfff")
GOLD = (255, 205, 96)


def ui(size, bold=False):
    return gfx.font("segoeuib.ttf" if bold else "segoeui.ttf", size)


def semi(size):
    return gfx.font("seguisb.ttf", size)


def code(size):
    return gfx.font("consola.ttf", size)


def canvas():
    img = Image.new("RGBA", (FW, FH), BG_DARK + (255,))
    d = ImageDraw.Draw(img)
    for i in range(24):
        y0, y1 = i * FH // 24, (i + 1) * FH // 24
        d.rectangle((0, y0, FW, y1), fill=gfx.mix(hx("1b1d2b"), hx("101119"), i / 23))
    return img


def ptot(img, x, y, k=10, **kw):
    """A pixel tot dropped into the smooth world, feet at (x, y)."""
    gfx.put(img, gfx.glow_img(int(14 * k), (255, 200, 120), 0.35), x, y - 12 * k, anchor="center")
    gfx.put(img, gfx.tot_img(k=k, **kw), x, y)


def alpha_text(img, xy, s, f, fill, a=1.0, anchor="la"):
    if a <= 0:
        return
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).text(xy, s, font=f, fill=fill + (int(255 * clamp01(a)),), anchor=anchor)
    img.alpha_composite(layer)


# ------------------------------------------------------------------------------------------- the desk mock

WX, WY, WW, WH = 700, 150, 1140, 760
TABS = ["Dashboard", "Chat", "Tasks", "Swarm", "Tater-tots", "Hub", "Settings"]


def window(img):
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((WX + 10, WY + 16, WX + WW + 10, WY + WH + 16), 18, fill=(6, 6, 10))  # shadow
    d.rounded_rectangle((WX, WY, WX + WW, WY + WH), 16, fill=BG, outline=BORDER, width=2)
    d.rounded_rectangle((WX, WY, WX + WW, WY + 56), 16, fill=BG_DARK)
    d.rectangle((WX, WY + 40, WX + WW, WY + 56), fill=BG_DARK)
    for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        d.ellipse((WX + 20 + i * 24, WY + 20, WX + 34 + i * 24, WY + 34), fill=c)
    d.text((WX + 110, WY + 15), "NL-Veil", font=semi(22), fill=FG_DIM)
    x = WX + 220
    for t in TABS:
        f = semi(20)
        w = f.getlength(t)
        if t == "Tater-tots":
            d.rounded_rectangle((x - 14, WY + 10, x + w + 14, WY + 46), 8, fill=BG_SEL)
            d.text((x, WY + 15), t, font=f, fill=FG)
            d.rectangle((x - 4, WY + 46, x + w + 4, WY + 49), fill=BLUE)
        else:
            d.text((x, WY + 15), t, font=f, fill=COMMENT)
        x += w + 38
    # roster
    d.rectangle((WX + 2, WY + 58, WX + 350, WY + WH - 2), fill=BG_HL)
    d.text((WX + 24, WY + 76), "TATER-TOTS  2 of 24", font=semi(18), fill=COMMENT)
    d.text((WX + 330, WY + 76), "limit  -  +", font=semi(16), fill=COMMENT, anchor="ra")
    rows = (("Gary", GREEN, "working", "llama-3.3-70b  ·  every 5s", "3 minds  ·  calls: unlimited"), ("Ada", YELLOW, "roaming", "llama-3.3-70b  ·  every 60s", "1 mind  ·  400 calls/day"))
    for i, (name, col, state, l1, l2) in enumerate(rows):
        y = WY + 110 + i * 116
        if i == 0:
            d.rounded_rectangle((WX + 14, y, WX + 338, y + 104), 10, fill=BG_SEL)
        d.ellipse((WX + 30, y + 22, WX + 44, y + 36), fill=col)
        d.text((WX + 56, y + 14), name, font=ui(26, True), fill=FG)
        d.text((WX + 330, y + 18), state, font=ui(18), fill=col, anchor="ra")
        d.text((WX + 56, y + 50), l1, font=ui(17), fill=FG_DIM)
        d.text((WX + 56, y + 74), l2, font=ui(17), fill=COMMENT)
    d.rounded_rectangle((WX + 24, WY + WH - 80, WX + 326, WY + WH - 30), 10, outline=BLUE, width=2)
    d.text((WX + 175, WY + WH - 55), "+  Deploy a tater-tot", font=semi(20), fill=BLUE, anchor="mm")


def panel_rect():
    return (WX + 370, WY + 76, WX + WW - 20, WY + WH - 20)


def form(img, lt, typed="", checked=False, deployed=False):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = panel_rect()
    d.text((x0, y0), "Deploy a tater-tot", font=ui(30, True), fill=FG)
    d.text((x0, y0 + 44), "It runs in your own Cloudflare account. Your computer can be off.", font=ui(18), fill=COMMENT)
    fields = (("Goal", typed + ("|" if int(lt * 3) % 2 == 0 and not deployed else ""), 96), ("Model", "@cf/meta/llama-3.3-70b-instruct-fp8-fast   ▾", 50), ("Pace", "every 5 seconds   ▾", 50), ("Model calls per day", "unlimited   ▾", 50))
    y = y0 + 96
    for label, val, h in fields:
        d.text((x0, y), label, font=semi(18), fill=FG_DIM)
        d.rounded_rectangle((x0, y + 28, x1, y + 28 + h), 8, fill=BG_DARK, outline=BLUE if label == "Goal" else BORDER, width=2)
        d.text((x0 + 16, y + 40), val, font=ui(20), fill=FG if val.strip("|") else COMMENT)
        y += 28 + h + 22
    d.rounded_rectangle((x0, y + 4, x0 + 28, y + 32), 6, outline=FG_DIM, width=2, fill=BLUE if checked else None)
    if checked:
        d.line((x0 + 6, y + 18, x0 + 12, y + 25, x0 + 23, y + 10), fill=BG_DARK, width=4)
    d.text((x0 + 42, y + 6), "May use this machine (asked once, at deployment)", font=ui(19), fill=FG)
    bx = x1 - 200
    d.rounded_rectangle((bx, y1 - 64, x1, y1), 12, fill=GREEN if deployed else BLUE)
    d.text(((bx + x1) / 2, y1 - 32), "Deployed" if deployed else "Deploy", font=ui(24, True), fill=BG_DARK, anchor="mm")


KIND_COL = {"pick": CYAN, "act": FG_DIM, "verdict": GREEN, "lesson": MAGENTA, "status": BLUE, "goal": YELLOW}


def console(img, rows, shown, expanded=None):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = panel_rect()
    d.text((x0, y0), "Gary", font=ui(30, True), fill=FG)
    d.text((x0 + 90, y0 + 10), "working  ·  goal: keep our docs in step with the code  ·  forever", font=ui(18), fill=COMMENT)
    d.rounded_rectangle((x0, y0 + 56, x1, y1), 10, fill=BG_DARK, outline=BORDER)
    y = y0 + 74
    for i, (r, kind, s, bad) in enumerate(rows[: int(shown)]):
        if bad:
            d.rectangle((x0 + 4, y - 6, x1 - 4, y + 30), fill=(60, 26, 38))
        d.text((x0 + 18, y), r, font=code(20), fill=COMMENT)
        d.text((x0 + 70, y), kind, font=code(20), fill=RED if bad else KIND_COL.get(kind, FG))
        d.text((x0 + 180, y), s, font=code(20), fill=RED if bad else FG)
        y += 40
        if expanded == i:
            for part in ("this page asks its visitor to prove they are human.", "A tater-tot does not solve those; it moves on."):
                d.text((x0 + 180, y), part, font=code(18), fill=FG_DIM)
                y += 30
            y += 8


KEEPS = [
    ("r1", "pick", "read the docs index; list what is stale", False),
    ("", "act", "web_fetch docs/index -> 41 pages", False),
    ("", "act", "run_python check_links.py -> exit ok", False),
    ("r1", "verdict", "improved [12/41]: stale.md written", False),
    ("r2", "pick", "fix the five stalest pages", False),
    ("", "act", "edit_file setup.md -> 1 passage replaced", False),
    ("r2", "verdict", "improved [17/41]", False),
]
LEARN = [
    ("r3", "pick", "check the forum thread the docs link to", False),
    ("", "act", "browser_open forum/thread -> BOT CHECK", True),
    ("r3", "verdict", "same: the page was a bot check", False),
    ("", "lesson", "read the source repo, not a page behind a check", False),
    ("r4", "verdict", "improved [27/41]", False),
]


def laptop(img, lt):
    d = ImageDraw.Draw(img)
    cx, base = WX + WW // 2, WY + 560
    close = ease_io(seg(lt, 0.15, 0.85))
    w = 560
    d.polygon(((cx - w / 2 - 40, base), (cx + w / 2 + 40, base), (cx + w / 2 + 70, base + 34), (cx - w / 2 - 70, base + 34)), fill=(150, 156, 176))
    lid_h = 360 * (1 - close) + 14 * close
    top = base - lid_h
    d.polygon(((cx - w / 2, base), (cx + w / 2, base), (cx + w / 2 - 10 * close, top), (cx - w / 2 + 10 * close, top)), fill=(110, 116, 134))
    if close < 0.9:
        sc = (cx - w / 2 + 18, top + 18, cx + w / 2 - 18, base - 10)
        if sc[3] > sc[1] + 4:
            d.rectangle(sc, fill=BG)
            if sc[3] - sc[1] > 60:
                d.text((cx, (sc[1] + sc[3]) / 2), "Tater-tots", font=ui(int(30 * (1 - close)) + 10, True), fill=FG, anchor="mm")
    if close > 0.95:
        for i in range(3):
            a = clamp01((lt - 0.9 - i * 0.12) / 0.2)
            alpha_text(img, (cx + 260 + i * 40, base - 120 - i * 50), "z", ui(48 + i * 14, True), FG_DIM, a)
        alpha_text(img, (cx, base + 90), "your tater-tots keep working in the cloud", ui(30), FG_DIM, clamp01((lt - 1.0) / 0.2), anchor="mm")


def tail_log(img, lt):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = WX + 40, WY + 40, WX + WW - 40, WY + WH - 40
    d.rounded_rectangle((x0, y0, x1, y1), 12, fill=(8, 8, 12), outline=BORDER, width=2)
    d.rounded_rectangle((x0, y0, x1, y0 + 44), 12, fill=(30, 32, 46))
    d.rectangle((x0, y0 + 30, x1, y0 + 44), fill=(30, 32, 46))
    d.text((x0 + 20, y0 + 10), "terminal", font=ui(18), fill=FG_DIM)
    d.text((x0 + 24, y0 + 64), "$ tail -f _tots/Gary-20261002-091500/events.log", font=code(22), fill=GREEN)
    lines = [
        "09:15:03  r1  pick     read the docs index; list what is stale",
        "09:15:05      act      web_fetch docs/index -> 41 pages",
        "09:15:09      act      run_python check_links.py -> exit ok",
        "09:15:12  r1  verdict  improved [12/41]",
        "09:15:17  r2  pick     fix the five stalest pages",
        "09:15:22      act      edit_file setup.md -> 1 passage replaced",
        "09:15:26  r2  verdict  improved [17/41]",
        "09:15:31  r3  pick     check the forum thread the docs link to",
        "09:15:33      act      browser_open forum/thread -> BOT CHECK",
        "09:15:36  r3  verdict  same: the page was a bot check",
        "09:15:37      lesson   read the source repo, not a page behind a check",
        "09:15:42  r4  verdict  improved [27/41]",
    ]
    n = int(seg(lt, 0.1, 1.0) * len(lines)) + 1
    y = y0 + 110
    for ln in lines[:n][-14:]:
        col = GREEN if "improved" in ln else RED if "BOT CHECK" in ln else MAGENTA if "lesson" in ln else FG_DIM
        d.text((x0 + 24, y), ln, font=code(20), fill=col)
        y += 36


def repo(img, lt):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = WX + 90, WY + 140, WX + WW - 90, WY + 560
    d.rounded_rectangle((x0, y0, x1, y1), 16, fill=BG, outline=BORDER, width=2)
    d.text((x0 + 40, y0 + 36), "gary23w / nl-veil", font=ui(44, True), fill=BLUE)
    d.text((x0 + 40, y0 + 104), "The veil: chat, swarms, goal loops - and tater-tots.", font=ui(24), fill=FG_DIM)
    d.rounded_rectangle((x0 + 40, y0 + 160, x0 + 236, y0 + 204), 22, fill=BG_SEL)
    d.text((x0 + 138, y0 + 182), "MIT License", font=semi(20), fill=FG, anchor="mm")
    d.rounded_rectangle((x0 + 256, y0 + 160, x0 + 420, y0 + 204), 22, fill=BG_SEL)
    d.text((x0 + 338, y0 + 182), "open source", font=semi(20), fill=FG, anchor="mm")
    for i, (lab, col) in enumerate((("Fork", GREEN), ("Star", YELLOW))):
        bx = x1 - 380 + i * 190
        pressed = lab == "Fork" and lt > 0.55
        d.rounded_rectangle((bx, y0 + 36, bx + 170, y0 + 92), 12, fill=col if pressed else BG_HL, outline=col, width=2)
        d.text((bx + 85, y0 + 64), lab, font=ui(26, True), fill=BG_DARK if pressed else col, anchor="mm")
    ptot(img, x1 - 120, y1 - 20, k=8, hat=True, arms="up" if lt > 0.55 else "down")


BEAT = 1.35
BEATS = [
    ("SPAWN A TATER-TOT", "Potato-as-a-Service, in your own account", "spawn"),
    ("GIVE IT A GOAL", "it will ketchup on your backlog", "goal"),
    ("CLOSE YOUR LAPTOP", "it works with your machine OFF", "laptop"),
    ("IT KEEPS GOING", "never a couch potato", "keeps"),
    ("WATCH IT LEARN", "deep fry learning: every fail becomes a rule", "learn"),
    ("TAIL ITS LOG", "every run, mirrored to your machine", "tail"),
    ("FORK IT.", "MIT licensed. make it yours.", "fork"),
]


def beats(_img, lt):
    i = min(len(BEATS) - 1, int(lt / BEAT))
    bt = lt - i * BEAT
    head, sub, kind = BEATS[i]
    img = canvas()
    if kind in ("spawn", "goal", "keeps", "learn"):
        window(img)
    if kind == "spawn":
        form(img, bt, "", checked=bt > 0.6)
    elif kind == "goal":
        goal = "keep our docs in step with the code"
        typed = goal[: int(seg(bt, 0.05, 0.8) * len(goal))]
        form(img, bt, typed, checked=True, deployed=bt > 0.95)
    elif kind == "laptop":
        laptop(img, bt)
    elif kind == "keeps":
        console(img, KEEPS, 1 + seg(bt, 0.05, 1.0) * (len(KEEPS) - 1) + 0.999)
    elif kind == "learn":
        console(img, LEARN, 1 + seg(bt, 0.05, 0.9) * (len(LEARN) - 1) + 0.999, expanded=1 if bt > 0.35 else None)
    elif kind == "tail":
        tail_log(img, bt)
    elif kind == "fork":
        repo(img, bt)
    x = lerp(-500, 110, ease_out(seg(bt, 0, 0.18)))
    d = ImageDraw.Draw(img)
    lines = head.split(" ") if len(head) > 12 else [head]
    if len(lines) > 2:
        lines = [" ".join(lines[:2]), " ".join(lines[2:])]
    y = 380 - 60 * (len(lines) - 1)
    for ln in lines:
        d.text((x, y), ln, font=ui(84, True), fill=FG)
        y += 110
    alpha_text(img, (x + 4, y + 10), sub, ui(30), FG_DIM, seg(bt, 0.1, 0.3))
    d.text((110, FH - 70), "NL-VEIL  ·  TATER-TOTS", font=semi(20), fill=COMMENT)
    return img


def meet(_img, lt):
    img = canvas()
    a = seg(lt, 0.0, 0.3)
    y = lerp(470, 430, ease_out(a))
    alpha_text(img, (FW // 2, y), "MEET TATER-TOTS.", ui(150, True), FG, a, anchor="mm")
    alpha_text(img, (FW // 2, y + 130), "Bite-sized agents. Full-sized results.", ui(54), FG_DIM, seg(lt, 0.45, 0.75), anchor="mm")
    if lt > 0.8:
        hop = math.sin(seg(lt, 0.8, 1.1) * math.pi) * 40
        ptot(img, 1640, 1000 - hop, k=12, hat=True, arms="wave" if lt > 1.1 else "down")
    return img


def triple(_img, lt):
    img = canvas()
    for i, (s, col) in enumerate((("OPEN SOURCE.", FG), ("AUTONOMOUS.", FG), ("EXTREMELY POTATO.", GOLD))):
        at = i * 0.45
        a = seg(lt, at, at + 0.2)
        y = lerp(330 + i * 150 + 40, 330 + i * 150, ease_out(a))
        alpha_text(img, (FW // 2, y), s, ui(118, True), col, a, anchor="mm")
    x = lerp(-200, FW + 200, seg(lt, 0.1, 2.0))
    ph = int(lt * 10) % 4
    gfx.put(img, gfx.glow_img(110, (255, 200, 120), 0.3), x, 940, anchor="center")
    gfx.put(img, gfx.tot_img(k=8, step=(0, 1, 0, 2)[ph], hat=False), x, 1040 - (8 if ph in (1, 3) else 0))
    return img


def final(_img, lt):
    img = canvas()
    d = ImageDraw.Draw(img)
    a = seg(lt, 0, 0.25)
    alpha_text(img, (FW // 2, 300), "NL-VEIL", ui(180, True), FG, a, anchor="mm")
    alpha_text(img, (FW // 2, 470), "TATER-TOTS ARE HERE.", ui(100, True), GOLD, seg(lt, 0.25, 0.5), anchor="mm")
    if lt > 0.5:
        s = 'veil --tater deploy "<goal>"'
        f = code(48)
        w = f.getlength(s)
        d.rounded_rectangle((FW / 2 - w / 2 - 36, 575, FW / 2 + w / 2 + 36, 665), 18, fill=BG_HL, outline=BORDER, width=2)
        d.text((FW / 2, 620), s, font=f, fill=GREEN, anchor="mm")
    alpha_text(img, (FW // 2, 740), "defending humanity from the AI apocalypse, one bite at a time.", ui(34), FG_DIM, seg(lt, 0.7, 1.0), anchor="mm")
    alpha_text(img, (FW // 2, 800), "dots are fine too, we guess.", gfx.font("segoeuii.ttf", 30), COMMENT, seg(lt, 1.0, 1.3), anchor="mm")
    if lt > 1.8:
        s = bounce(seg(lt, 1.8, 2.05))
        k = max(1, int(14 * s))
        ptot(img, 1650, 1080 - 40 + int((1 - s) * 200), k=k, hat=True, arms="wave")
        if lt > 1.95:
            d.rounded_rectangle((1480, 560, 1860, 650), 30, fill=(255, 255, 255))
            d.polygon(((1600, 640), (1650, 640), (1640, 700)), fill=(255, 255, 255))
            d.text((1670, 605), "but we're better.", font=ui(40, True), fill=BG_DARK, anchor="mm")
    return img


def black(_img, lt):
    return Image.new("RGBA", (FW, FH), (0, 0, 0, 255))
