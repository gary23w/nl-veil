"""Render the tots release video.

    python render.py                 the whole video -> ../tots-release.mp4
    python render.py --preview 3.1 20.5 ...   single frames -> preview/<t>.png
    python render.py --audio         the soundtrack alone -> soundtrack.wav
"""
import math
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image
from scipy.io import wavfile

import gfx
import scenes
import audio

FPS = 30
OUT_W, OUT_H = 1920, 1080
HERE = os.path.dirname(os.path.abspath(__file__))


def shake_at(t):
    dx = dy = 0.0
    for t0, amp, dur in scenes.SHAKE:
        u = t - t0
        if 0 <= u < dur:
            a = amp * (1 - u / dur)
            dx += a * math.sin(u * 91)
            dy += a * math.cos(u * 73)
    return int(round(dx)), int(round(dy))


def frame(t):
    for t0, t1, fn, hires in scenes.SHOTS:
        if t0 <= t < t1:
            break
    else:
        return Image.new("RGB", (OUT_W, OUT_H))
    lt = t - t0
    if hires:
        return fn(None, lt).convert("RGB")
    img = Image.new("RGBA", (gfx.W, gfx.H), (0, 0, 0, 255))
    out = fn(img, lt)
    img = out if out is not None else img
    sx, sy = shake_at(t)
    if sx or sy:
        moved = Image.new("RGBA", img.size, (0, 0, 0, 255))
        moved.paste(img, (sx, sy))
        img = moved
    for a, b, speaker, line, where in scenes.SAY:
        if a <= t < b:
            gfx.dialogue(img, speaker, line, t - a, where=where)
    return img.convert("RGB").resize((OUT_W, OUT_H), Image.NEAREST)


def soundtrack(path):
    x = audio.mix(scenes.TOTAL, scenes.MUSIC, scenes.CUES, scenes.SAY)
    wavfile.write(path, audio.SR, (x * 32767).astype(np.int16))


def main():
    args = sys.argv[1:]
    if args and args[0] == "--preview":
        os.makedirs(os.path.join(HERE, "preview"), exist_ok=True)
        for s in args[1:]:
            t = float(s)
            frame(t).save(os.path.join(HERE, "preview", f"{t:06.2f}.png"))
        print("total", round(scenes.TOTAL, 2), "s")
        return
    wav = os.path.join(HERE, "soundtrack.wav")
    t_a = time.time()
    soundtrack(wav)
    print(f"soundtrack: {time.time() - t_a:.1f}s")
    if args and args[0] == "--audio":
        return
    out = os.path.join(os.path.dirname(HERE), "tots-release.mp4")
    n = int(scenes.TOTAL * FPS)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-",
           "-i", wav, "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
           "-movflags", "+faststart", "-shortest", out]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    t_v = time.time()
    for i in range(n):
        p.stdin.write(frame(i / FPS).tobytes())
        if i % 300 == 0:
            print(f"frame {i}/{n}  {time.time() - t_v:.0f}s", flush=True)
    p.stdin.close()
    p.wait()
    print("wrote", out, f"({scenes.TOTAL:.1f}s, {time.time() - t_v:.0f}s to render)")


if __name__ == "__main__":
    main()
