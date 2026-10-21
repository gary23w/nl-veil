"""Render the short: TATER-TOTS vs THE AI APOCALYPSE, vertical 1080x1920.

    python render.py                        the whole short -> ../tots-vs-the-ai-apocalypse.mp4
    python render.py --preview 3.1 20.5     single frames -> <work>/preview/<t>.png
    python render.py --sheet [step]         every `step` seconds on one contact sheet -> <work>/sheet.png
    python render.py --audio                the soundtrack alone -> <work>/soundtrack.wav
    add --square to any of these for the 1:1 cut (1080x1080) -> ../tots-vs-the-ai-apocalypse-square.mp4

Intermediate files go to the work folder: $TOTS_WORK, or tots-apocalypse in the system temp folder.
"""
import math
import os
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image
from scipy.io import wavfile

import art
import shots
import sound

SQUARE = "--square" in sys.argv
if SQUARE:
    sys.argv.remove("--square")
    shots.SQUARE[0] = True

FPS = 30
K = 4
VIEW_H = art.W if SQUARE else art.H  # rows of the 270-wide picture that make it to the frame
OUT_W, OUT_H = art.W * K, VIEW_H * K
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get("TOTS_WORK") or os.path.join(tempfile.gettempdir(), "tots-apocalypse")
if SQUARE:
    WORK = os.path.join(WORK, "square")
OUT = os.path.join(os.path.dirname(HERE), "tots-vs-the-ai-apocalypse" + ("-square" if SQUARE else "") + ".mp4")


def shake_at(t):
    dx = dy = 0.0
    for t0, amp, dur in shots.SHAKE:
        u = t - t0
        if 0 <= u < dur:
            a = amp * (1 - u / dur)
            dx += a * math.sin(u * 91)
            dy += a * math.cos(u * 73)
    return dx, dy


def frame(t):
    for t0, t1, fn in shots.SHOTS:
        if t0 <= t < t1:
            break
    else:
        return Image.new("RGB", (OUT_W, OUT_H))
    lt = t - t0
    shots.CAM.clear()
    shots.UI[0] = Image.new("RGBA", (art.W, VIEW_H), (0, 0, 0, 0))
    img = fn(lt)
    for a, b, speaker, line, where, sq_where in shots.SAY:
        if a <= t < b:
            art.dialogue(shots.UI[0], speaker, line, t - a, where=sq_where if SQUARE else where)
    z = max(1.0, shots.CAM.get("z", 1.0))
    hw, hh = art.W / (2 * z), VIEW_H / (2 * z)
    cy = shots.CAM.get("cy", art.H / 2)
    if SQUARE:  # each shot says which rows of its picture the square shows
        f = shots.SQ_CY.get(fn.__name__)
        v = f(lt) if callable(f) else f
        if v is not None:
            cy = v
    cx = min(max(shots.CAM.get("cx", art.W / 2), hw), art.W - hw)
    cy = min(max(cy, hh), art.H - hh)
    out = img.resize((OUT_W, OUT_H), Image.NEAREST, box=(cx - hw, cy - hh, cx + hw, cy + hh))
    sx, sy = shake_at(t)
    if abs(sx) >= 0.25 or abs(sy) >= 0.25:
        moved = Image.new("RGBA", out.size, (0, 0, 0, 255))
        moved.paste(out, (int(round(sx * K * z)), int(round(sy * K * z))))
        out = moved
    out.alpha_composite(shots.UI[0].resize((OUT_W, OUT_H), Image.NEAREST))
    return out.convert("RGB")


def soundtrack(path):
    x = sound.mix(shots.TOTAL, shots.MUSIC, shots.CUES, shots.SAY)
    wavfile.write(path, sound.SR, (x * 32767).astype(np.int16))


def sheet(step):
    ts = np.arange(0.05, shots.TOTAL, step)
    tw, th = OUT_W // 8, OUT_H // 8
    cols = 10 if not SQUARE else 14
    rows = (len(ts) + cols - 1) // cols
    sh = Image.new("RGB", (cols * tw, rows * th), (40, 40, 40))
    for i, t in enumerate(ts):
        sh.paste(frame(float(t)).resize((tw, th), Image.BILINEAR), ((i % cols) * tw, (i // cols) * th))
    path = os.path.join(WORK, "sheet.png")
    sh.save(path)
    print("wrote", path, len(ts), "frames")


def main():
    os.makedirs(WORK, exist_ok=True)
    args = sys.argv[1:]
    if args and args[0] == "--preview":
        os.makedirs(os.path.join(WORK, "preview"), exist_ok=True)
        for s in args[1:]:
            t = float(s)
            frame(t).save(os.path.join(WORK, "preview", f"{t:06.2f}.png"))
        print("total", round(shots.TOTAL, 2), "s")
        return
    if args and args[0] == "--sheet":
        sheet(float(args[1]) if len(args) > 1 else 1.0)
        return
    wav = os.path.join(WORK, "soundtrack.wav")
    t_a = time.time()
    soundtrack(wav)
    print(f"soundtrack: {time.time() - t_a:.1f}s")
    if args and args[0] == "--audio":
        return
    n = int(shots.TOTAL * FPS)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-",
           "-i", wav, "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
           "-movflags", "+faststart", "-shortest", OUT]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    t_v = time.time()
    for i in range(n):
        p.stdin.write(frame(i / FPS).tobytes())
        if i % 300 == 0:
            print(f"frame {i}/{n}  {time.time() - t_v:.0f}s", flush=True)
    p.stdin.close()
    p.wait()
    print("wrote", OUT, f"({shots.TOTAL:.1f}s, {time.time() - t_v:.0f}s to render)")


if __name__ == "__main__":
    main()
