"""The short's soundtrack, synthesized: a chiptune cue per section, the new sound effects, and dialogue blips.

The instruments, drums and the older effects come from ../render/audio.py; everything here builds on them.
"""
import math

import numpy as np

import art  # noqa: F401 - puts ../render on the path
import audio
from audio import SR, midi, tt, osc, env, lp_fast, sweep, inst, place, song, chord_arp

RNG = np.random.default_rng(23)


def noise(n):
    return RNG.uniform(-1, 1, n)


def hp(x, k=3):
    return x - lp_fast(x, k)


def band(x, lo=3, hi=20):
    return lp_fast(x, lo) - lp_fast(x, hi)


# ------------------------------------------------------------------------------------------- music

def track(buf, name, t0, t1):
    if name == "hookrun":
        notes = chord_arp([(64, 67, 71)], 4, 0.25, 2, "arp", 0.16)
        notes += [(b * 0.5, 40 + (12 if b % 2 else 0), 0.5, "bass", 0.3) for b in range(8)]
        notes += [(0, 76, 1, "lead50", 0.22), (1, 79, 0.5, "lead50", 0.22)]
        dr = [(b, "kick", 0.9) for b in range(4)] + [(b, "snare", 0.8) for b in (1, 3)] + [(b * 0.5, "hat", 0.5) for b in range(8)]
        song(buf, t0, t1, 168, 4, notes, dr, fade_in=0.0, fade_out=0.01, vol=0.85)
    elif name == "lab":
        mel = [(0, 72, .5), (.5, 76, .5), (1, 79, .5), (1.5, 76, .5), (2, 77, .5), (2.5, 81, .5), (3, 79, 1), (4, 74, .5), (4.5, 77, .5),
               (5, 81, .5), (5.5, 79, .5), (6, 76, 1), (7, 72, 1)]
        notes = [(b, m, l, "pluck", 0.32) for b, m, l in mel]
        notes += [(b, m, 0.45, "tbass", 0.3) for b, m in ((0, 48), (1, 55), (2, 53), (3, 55), (4, 50), (5, 57), (6, 55), (7, 48))]
        notes += [(b + 0.5, m, 0.3, "bell", 0.05) for b, m in zip(range(8), (84, 88, 91, 88, 86, 89, 93, 89))]
        song(buf, t0, t1, 120, 8, notes, [(b + 0.5, "hat", 0.25) for b in range(8)], fade_in=0.2, fade_out=0.02, vol=0.9)
    elif name == "dread":
        notes = [(0, 38, 8, "pad", 0.32), (0, 39, 8, "pad", 0.18), (0, 50, 8, "choir", 0.12), (0, 57, 8, "choir", 0.08)]
        dr = [(b, "kick", 0.55) for b in (0, 2, 4, 6)] + [(b + 0.35, "kick", 0.35) for b in (0, 2, 4, 6)]
        song(buf, t0, t1, 120, 8, notes, dr, fade_in=0.3, fade_out=0.1, vol=0.8)
        n = int((t1 - t0) * SR)
        riser = sweep(120, 900, n, "saw", curve=2.2) * np.linspace(0, 0.08, n)
        place(buf, t0, lp_fast(riser, 4))
    elif name == "doom":
        roots = [38, 38, 41, 38, 43, 41, 40, 36]
        notes = []
        for b, r in enumerate(roots):
            notes += [(b, r, 0.5, "bass", 0.32), (b + 0.5, r + 12, 0.5, "bass", 0.26)]
        for b, ch, l in ((0, (62, 65, 69), 1.5), (4, (58, 62, 65), 1.5), (6, (57, 61, 64), 2)):
            notes += [(b, m, l, "brass", 0.16) for m in ch]
        notes += [(0, 50, 8, "choir", 0.1), (0, 57, 8, "choir", 0.08)]
        mel = [(0, 74, 1.5), (1.5, 72, .5), (2, 69, 2), (4, 70, 1.5), (5.5, 69, .5), (6, 73, 2)]
        notes += [(b, m, l, "lead50", 0.16) for b, m, l in mel]
        dr = [(b, "kick", 0.95) for b in range(8)] + [(b, "snare", 0.8) for b in (1, 3, 5, 7)] + [(b * 0.5, "hat", 0.45) for b in range(16)] + [(0, "timp", 0.8), (4, "timp", 0.7)]
        song(buf, t0, t1, 140, 8, notes, dr, fade_in=0.02, fade_out=0.25, vol=0.85)
    elif name == "noir":
        walk = [38, 41, 45, 49, 50, 48, 46, 45]
        notes = [(b, m, 0.9, "tbass", 0.42) for b, m in enumerate(walk)]
        mel = [(0.5, 69, .5), (1, 74, 1), (2, 77, .75), (2.75, 76, .25), (3, 74, 1), (4.5, 73, .5), (5, 76, 1.5), (6.5, 74, 1.5)]
        notes += [(b, m, l, "lead", 0.13) for b, m, l in mel]
        notes += [(0, m, 4, "organ", 0.07) for m in (62, 65, 69)] + [(4, m, 4, "organ", 0.07) for m in (61, 64, 70)]
        dr = [(b + s, "hat", 0.22 if s else 0.3) for b in range(8) for s in (0, 0.66)] + [(b, "kick", 0.4) for b in (0, 4)] + [(b, "snare", 0.25) for b in (2, 6)]
        song(buf, t0, t1, 76, 8, notes, dr, fade_in=0.4, fade_out=0.3, vol=0.9)
    elif name == "rain":
        n = int((t1 - t0) * SR)
        x = band(noise(n), 2, 14) * 0.5
        x *= 0.75 + 0.25 * np.sin(np.linspace(0, 9, n))
        drops = (RNG.random(n) > 0.9993) * RNG.uniform(0.3, 1.0, n)
        x += lp_fast(drops, 2) * 0.6
        fi = int(0.5 * SR)
        x[:fi] *= np.linspace(0, 1, fi)
        x[-fi:] *= np.linspace(1, 0, fi)
        place(buf, t0, x, 0.22)
    elif name == "march":
        theme = [(0, 62, .75), (.75, 62, .25), (1, 69, 1), (2, 67, .5), (2.5, 66, .5), (3, 64, .5), (3.5, 66, .5), (4, 67, 1.5), (5.5, 69, .5), (6, 74, 2)]
        notes = [(b, m, l, "brass", 0.28) for b, m, l in theme]
        for b, ch, l in ((0, (50, 54, 57), 4), (4, (55, 59, 62), 2), (6, (57, 61, 64), 2)):
            notes += [(b, m, l, "organ", 0.1) for m in ch]
            notes += [(b, ch[0] - 12, l, "tbass", 0.36)]
        dr = [(b, "kick", 0.8) for b in (0, 2, 4, 6)] + [(b * 0.25, "snare", 0.18 + 0.03 * (b % 4 == 0)) for b in range(32)] + [(b, "timp", 0.6) for b in (0, 4)]
        song(buf, t0, t1, 120, 8, notes, dr, fade_in=0.05, fade_out=0.05, vol=0.85)
    elif name == "battle":
        chords = [(64, 67, 71), (60, 64, 67), (62, 66, 69), (59, 63, 66)]
        roots = [40, 36, 38, 35]
        notes = chord_arp(chords, 4, 0.25, 2, "arp", 0.13)
        for ci, r in enumerate(roots):
            notes += [(ci * 4 + e * 0.5, r + (12 if e % 2 else 0), 0.5, "bass", 0.3) for e in range(8)]
        mel = [(0, 76, 1), (1, 79, .5), (1.5, 78, .5), (2, 76, 1), (3, 71, 1), (4, 72, 1.5), (5.5, 74, .5), (6, 76, 2), (8, 74, 1), (9, 78, .5),
               (9.5, 79, .5), (10, 81, 2), (12, 83, 1.5), (13.5, 81, .5), (14, 78, 2)]
        notes += [(b, m, l, "lead50", 0.19) for b, m, l in mel]
        dr = [(b, "kick", 0.9) for b in range(16)] + [(b + 0.5, "kick", 0.5) for b in (3, 7, 11, 15)] + [(b, "snare", 0.8) for b in range(1, 16, 2)] + [(b * 0.5, "hat", 0.45) for b in range(32)]
        song(buf, t0, t1, 168, 16, notes, dr, fade_in=0.02, fade_out=0.08, vol=0.8)
    elif name == "boss":
        ost = [36, 36, 48, 36, 42, 36, 48, 36]
        notes = []
        for bar in range(2):
            for e, m in enumerate(ost):
                notes.append((bar * 4 + e * 0.5, m + (-4 if bar else 0), 0.5, "bass", 0.32))
        notes += [(0, m, 4, "choir", 0.12) for m in (60, 63, 67)] + [(4, m, 4, "choir", 0.12) for m in (56, 60, 63)]
        notes += [(b, m, 0.5, "brass", 0.18) for b, m in ((0, 72), (1.5, 72), (3, 78), (4, 68), (5.5, 68), (7, 74))]
        mel = [(0, 84, .5), (.5, 83, .5), (1, 84, 1), (2, 87, 1), (3, 86, 1), (4, 80, 1.5), (5.5, 83, .5), (6, 86, 2)]
        notes += [(b, m, l, "lead", 0.14) for b, m, l in mel]
        dr = [(b * 0.5, "kick", 0.8) for b in range(16)] + [(b, "snare", 0.85) for b in (1, 3, 5, 7)] + [(b * 0.25, "hat", 0.3) for b in range(32)] + [(0, "timp", 0.8), (4, "timp", 0.8)]
        song(buf, t0, t1, 150, 8, notes, dr, fade_in=0.05, fade_out=0.1, vol=0.85)
    elif name == "finale":
        theme = [(0, 74, .75), (.75, 74, .25), (1, 81, 1), (2, 79, .5), (2.5, 78, .5), (3, 76, .5), (3.5, 78, .5), (4, 79, 1.5), (5.5, 81, .5), (6, 86, 2)]
        notes = [(b, m, l, "brass", 0.3) for b, m, l in theme] + [(b, m - 12, l, "lead50", 0.1) for b, m, l in theme]
        chords = [(62, 66, 69), (62, 66, 69), (67, 71, 74), (69, 73, 76)]
        for ci, ch in enumerate(chords):
            notes += [(ci * 2, m, 2, "choir", 0.13) for m in ch] + [(ci * 2, ch[0] - 24, 2, "tbass", 0.34)]
        notes += chord_arp(chords, 2, 0.25, 2, "arp", 0.07)
        dr = [(b, "kick", 1.0) for b in range(8)] + [(b, "snare", 0.9) for b in (1, 3, 5, 7)] + [(b * 0.5, "hat", 0.5) for b in range(16)] + [(b, "timp", 0.7) for b in (0, 4)]
        song(buf, t0, t1, 150, 8, notes, dr, fade_in=0.02, fade_out=0.05, vol=0.9)
    elif name == "victory":
        notes = [(0, 74, .25, "lead50", 0.26), (.25, 78, .25, "lead50", 0.26), (.5, 81, .25, "lead50", 0.26), (.75, 86, 1.5, "brass", 0.3)]
        notes += [(.75, m, 1.5, "choir", 0.12) for m in (62, 66, 69, 74)] + [(.75, 50, 1.5, "tbass", 0.35)]
        mel = [(2.5, 81, .5), (3, 83, .5), (3.5, 81, .5), (4, 78, 1), (5, 79, .5), (5.5, 81, .5), (6, 86, 1.5)]
        notes += [(b, m, l, "tri", 0.22) for b, m, l in mel]
        notes += [(b, m, 2, "pad", 0.1) for b in (2.5, 4.5) for m in (62, 66, 69)]
        dr = [(.75, "timp", 1.0), (.75, "kick", 1.0)] + [(b + 2.5, "hat", 0.25) for b in range(6)] + [(b + 2.5, "kick", 0.4) for b in (0, 2, 4)]
        song(buf, t0, t1, 140, 9, notes, dr, fade_in=0.0, fade_out=0.3, vol=0.9)
    elif name == "lofi":
        chords = [(53, 57, 60, 64), (52, 55, 59, 62), (50, 53, 57, 60), (48, 52, 55, 59)]
        notes = []
        for ci, ch in enumerate(chords):
            notes += [(ci * 2, m, 1.9, "pad", 0.11) for m in ch] + [(ci * 2, ch[0] - 12, 1.8, "tbass", 0.3)]
            notes += [(ci * 2 + 0.5 + j * 0.5, m + 12, 0.4, "pluck", 0.09) for j, m in enumerate(ch[1:])]
        dr = [(b, "kick", 0.55) for b in (0, 2.5, 4, 6.5)] + [(b, "snare", 0.35) for b in (1, 3, 5, 7)] + [(b + s, "hat", 0.18) for b in range(8) for s in (0, 0.62)]
        song(buf, t0, t1, 84, 8, notes, dr, fade_in=0.3, fade_out=0.3, vol=0.85)
        n = int((t1 - t0) * SR)
        crackle = (RNG.random(n) > 0.9985) * RNG.uniform(-1, 1, n)
        place(buf, t0, hp(crackle, 2) * 0.3 + band(noise(n), 2, 30) * 0.015)
    elif name == "theme":
        notes = [(0, m, 3, "brass", 0.2) for m in (62, 66, 69, 74)] + [(0, m, 4, "choir", 0.12) for m in (62, 69, 74)] + [(0, 38, 3, "tbass", 0.4)]
        mel = [(3, 74, .75), (3.75, 74, .25), (4, 81, 1), (5, 79, .5), (5.5, 78, .5), (6, 79, 1), (7, 86, 2)]
        notes += [(b, m, l, "lead50", 0.2) for b, m, l in mel]
        notes += [(7, m, 2.5, "pad", 0.12) for m in (62, 66, 69, 74)]
        dr = [(0, "timp", 1.0), (0, "kick", 1.0), (7, "timp", 0.8)] + [(b, "hat", 0.25) for b in (3, 4, 5, 6)]
        song(buf, t0, t1, 140, 10, notes, dr, fade_in=0.0, fade_out=0.6, vol=0.9)


# ------------------------------------------------------------------------------------------- sound effects

def sfx(name, **kw):
    if name == "scratch":
        n = int(0.42 * SR)
        t = tt(n)
        f = 180 + 1500 * np.abs(np.sin(2 * math.pi * 2.6 * t)) ** 1.4
        ph = np.cumsum(f) / SR
        x = (2 * (ph % 1) - 1) * 0.5 + noise(n) * 0.7
        x = band(x, 2, 18)
        return x * env(n, 0.003, 0.3, 0.7, 0.04) * 1.1
    if name == "rewind":
        out = np.zeros(int(1.0 * SR))
        for i in range(9):
            m = int(0.09 * SR)
            place(out, i * 0.1, sweep(1400, 500, m, "sq", 0.5) * np.exp(-tt(m) * 12) * 0.08)
        out += band(noise(len(out)), 1, 6) * 0.08
        return out
    if name == "gulp":
        n = int(0.16 * SR)
        return sweep(320, 110, n, "sine", curve=0.6) * np.exp(-tt(n) * 14) * 0.5
    if name == "robo":
        out = np.zeros(int(0.32 * SR))
        for i in range(3):
            m = int(0.08 * SR)
            f = 170 + 40 * ((i * 7) % 3)
            x = osc("sq", f, m, 0.5) * osc("sq", 31, m, 0.5)
            place(out, i * 0.095, lp_fast(x, 3) * env(m, 0.004, 0.05, 0.7, 0.01) * 0.2)
        return out
    if name == "squash":
        n = int(0.3 * SR)
        return (lp_fast(noise(n), 6) * 1.4 + sweep(420, 60, n, "sine") * 0.6) * np.exp(-tt(n) * 12) * 0.7
    if name == "boing":
        n = int(0.6 * SR)
        t = tt(n)
        f = 220 + 380 * (1 - np.exp(-t * 6)) + 60 * np.sin(2 * math.pi * 22 * t) * np.exp(-t * 4)
        return np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t * 5) * 0.3
    if name == "thunder":
        n = int(1.8 * SR)
        crack = hp(noise(n), 2) * np.exp(-tt(n) * 18) * 0.8
        roll = lp_fast(noise(n), 60) * (0.6 + 0.4 * np.sin(np.linspace(0, 11, n))) * np.exp(-tt(n) * 1.6) * 3.2
        return crack + roll
    if name == "shing":
        n = int(0.7 * SR)
        t = tt(n)
        x = sum(osc("sine", f, n) * a for f, a in ((3100, 0.5), (4650, 0.3), (6200, 0.2)))
        return x * np.exp(-t * 6) * np.minimum(1, t * 400) * 0.22 + sweep(2000, 7000, n, "sine") * np.exp(-t * 20) * 0.08
    if name == "jump":
        n = int(0.16 * SR)
        return sweep(300, 950, n, "sq", 0.5) * env(n, 0.003, 0.1, 0.6, 0.02) * 0.12
    if name == "slash":
        n = int(0.35 * SR)
        t = tt(n)
        whsh = hp(noise(n), 2) * np.exp(-((t - 0.04) / 0.035) ** 2) * 0.9
        ring = (osc("sine", 2600, n) + 0.5 * osc("sine", 3900, n)) * np.exp(-t * 12) * 0.18
        return whsh + ring
    if name == "swoosh":
        n = int(0.5 * SR)
        x = band(noise(n), 4, 30)
        return x * np.sin(np.linspace(0, math.pi, n)) ** 2 * 0.9
    if name == "clang":
        n = int(1.0 * SR)
        t = tt(n)
        x = sum(osc("sine", f, n) * a * np.exp(-t * d) for f, a, d in ((520, 0.5, 4), (1350, 0.4, 5), (2230, 0.3, 7), (3170, 0.25, 9), (4410, 0.15, 12)))
        return x * 0.35 + lp_fast(noise(n), 5) * np.exp(-t * 40) * 0.6
    if name == "fall":
        n = int(0.32 * SR)
        return sweep(2200, 500, n, "sine") * env(n, 0.01, 0.3, 0.8, 0.03) * 0.18
    if name == "bonk":
        n = int(0.2 * SR)
        t = tt(n)
        return sweep(950, 640, n, "sine") * np.exp(-t * 30) * 0.5 + sweep(160, 70, n, "sine") * np.exp(-t * 20) * 0.6
    if name == "wahwah":
        out = np.zeros(int(1.8 * SR))
        for i, (m, at, d) in enumerate(((58, 0.0, 0.26), (57, 0.28, 0.26), (56, 0.56, 0.26), (55, 0.84, 0.85))):
            nn = int(d * SR)
            f = midi(m)
            t = tt(nn)
            vib = 1 + (0.03 * np.sin(2 * math.pi * 6 * t) if i == 3 else 0)
            x = 2 * ((np.cumsum(np.full(nn, f) * vib) / SR) % 1) - 1
            x = lp_fast(x, 5) * env(nn, 0.03, 0.1, 0.8, 0.08) * (0.6 + 0.4 * np.sin(np.linspace(0, math.pi, nn)))
            place(out, at, x, 0.22)
        return out
    if name == "throw":
        n = int(0.22 * SR)
        return band(noise(n), 2, 12) * np.sin(np.linspace(0, math.pi, n)) * 0.6
    if name == "coin":
        a, b = int(0.07 * SR), int(0.4 * SR)
        return np.concatenate([osc("sq", 988, a, 0.5) * 0.12, osc("sq", 1319, b, 0.5) * np.exp(-tt(b) * 7) * 0.12])
    if name == "key":
        n = int(0.03 * SR)
        f = 1800 + RNG.integers(0, 900)
        return (hp(noise(n), 2) * 0.5 + osc("sq", f, n, 0.5) * 0.15) * np.exp(-tt(n) * 160) * 0.5
    if name == "poof":
        n = int(0.4 * SR)
        return lp_fast(noise(n), 8) * np.exp(-tt(n) * 9) * 1.2
    if name == "charge":
        n = int(1.05 * SR)
        t = tt(n)
        x = sweep(90, 900, n, "saw", curve=1.6)
        trem = 0.6 + 0.4 * np.sign(np.sin(2 * math.pi * np.cumsum(6 + 30 * t) / SR))
        return lp_fast(x, 3) * trem * np.linspace(0.05, 0.22, n)
    if name == "beam":
        n = int(1.25 * SR)
        t = tt(n)
        x = osc("saw", 110, n) * 0.4 + osc("sq", 220, n, 0.3, vib=2) * 0.25 + noise(n) * 0.25
        x = lp_fast(x, 4) * (0.8 + 0.2 * np.sin(2 * math.pi * 17 * t))
        return x * env(n, 0.01, 0.2, 0.85, 0.2) * 0.45
    if name == "wheee":
        n = int(0.45 * SR)
        k = 1 + 0.08 * (kw.get("n", 0) % 4)
        t = np.linspace(0, 1, n)
        f = (900 + 900 * np.sin(t * math.pi)) * k
        return np.where((np.cumsum(f) / SR) % 1 < 0.5, 1.0, -1.0) * env(n, 0.01, 0.2, 0.7, 0.05) * 0.06
    if name == "thud":
        n = int(0.32 * SR)
        return (sweep(95, 38, n, "sine") * 0.9 + lp_fast(noise(n), 20) * 0.7) * np.exp(-tt(n) * 12)
    if name == "grass":
        out = np.zeros(int(1.6 * SR))
        n = len(out)
        place(out, 0, band(noise(n), 2, 10) * np.sin(np.linspace(0, math.pi, n)) * 0.35)
        for i, m in enumerate((74, 78, 81, 86, 90, 93, 98)):
            place(out, 0.05 + i * 0.09, inst("bell", m, 0.6), 0.22)
        return out
    if name == "vine":
        n = int(0.6 * SR)
        t = tt(n)
        f = 70 + 25 * np.sin(2 * math.pi * 3 * t)
        x = lp_fast(2 * ((np.cumsum(f) / SR) % 1) - 1, 8) * 0.4 + band(noise(n), 2, 8) * 0.25
        return x * np.sin(np.linspace(0, math.pi, n)) * 0.8
    if name == "cheer":
        out = np.zeros(int(0.5 * SR))
        for j in range(3):
            m = int(0.12 * SR)
            f0 = 1300 + 160 * ((kw.get("n", 0) * 3 + j * 5) % 5)
            place(out, j * 0.11, sweep(f0, f0 * 1.4, m, "sq", 0.5) * env(m, 0.005, 0.06, 0.6, 0.02) * 0.06)
        return out
    if name == "notif":
        a, b = int(0.06 * SR), int(0.25 * SR)
        return np.concatenate([osc("sine", 1320, a) * 0.25, osc("sine", 1760, b) * np.exp(-tt(b) * 12) * 0.25])
    if name == "step" and kw.get("soft"):
        return audio.sfx("step") * 0.35
    return audio.sfx(name, **kw)


# ------------------------------------------------------------------------------------------- voices

VOICE = {"tot": 1750, "scientist": 1300, "human": 1450}
ROBOT = {"bot": 600, "ackshually-bot": 600, "mod-bot": 520, "boss": 240}


def blip(speaker, n_):
    jitter = 1 + 0.04 * ((n_ * 7) % 5 - 2)
    if speaker.startswith("garrett"):
        n = int(0.05 * SR)
        f = 150 * jitter
        x = osc("sq", f, n, 0.3) * 0.6 + osc("sine", f / 2, n) * 0.5 + noise(n) * 0.15
        return lp_fast(x, 4) * np.exp(-tt(n) * 30) * 0.16
    if speaker in ROBOT:
        n = int((0.045 if speaker == "boss" else 0.03) * SR)
        x = osc("sq", ROBOT[speaker] * jitter, n, 0.5) * osc("sq", 55, n, 0.5)
        return x * np.exp(-tt(n) * 35) * (0.13 if speaker == "boss" else 0.09)
    n = int(0.028 * SR)
    return osc("sq", VOICE.get(speaker, 1200) * jitter, n, 0.5) * np.exp(-tt(n) * 40) * 0.09


def mix(total, music, cues, says):
    buf = np.zeros(int((total + 2) * SR))
    for t0, t1, name in music:
        track(buf, name, t0, t1)
    fx = np.zeros_like(buf)
    for t, name, kw in cues:
        place(fx, t, sfx(name, **kw))
    for t0, t1, speaker, line, *_ in says:
        n_ = 0
        step = 2 if not speaker.startswith("garrett") else 3
        for i, ch in enumerate(line):
            if ch == " " or i % step:
                continue
            tc = t0 + 0.08 + i / 30.0
            if tc > t1:
                break
            place(fx, tc, blip(speaker, n_))
            n_ += 1
    out = buf * 0.55 + fx
    out = np.tanh(out * 1.2) / np.tanh(1.2)
    peak = np.max(np.abs(out)) or 1.0
    out = out / peak * 0.89
    return out[: int(total * SR)]
