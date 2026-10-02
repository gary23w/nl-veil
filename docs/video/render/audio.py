"""The soundtrack, synthesized: chiptune music per section, sound effects, and dialogue blips."""
import math

import numpy as np

SR = 44100
RNG = np.random.default_rng(5)


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(n):
    return np.arange(n) / SR


def osc(kind, f, n, duty=0.5, vib=0.0):
    t = tt(n)
    ph = f * t
    if vib:
        ph = ph + vib * np.sin(2 * math.pi * 5.5 * t) / 5.5 * f * 0.006
    if kind == "sq":
        return np.where((ph % 1) < duty, 1.0, -1.0)
    if kind == "tri":
        return 2 * np.abs(2 * (ph % 1) - 1) - 1
    if kind == "saw":
        return 2 * (ph % 1) - 1
    if kind == "sine":
        return np.sin(2 * math.pi * ph)
    if kind == "noise":
        return RNG.uniform(-1, 1, n)
    raise ValueError(kind)


def env(n, a=0.005, d=0.12, s=0.5, r=0.04):
    e = np.ones(n) * s
    na, nd, nr = int(a * SR), int(d * SR), int(r * SR)
    na = min(na, n)
    e[:na] = np.linspace(0, 1, na) if na else e[:na]
    if nd and na < n:
        k = min(nd, n - na)
        e[na : na + k] = 1 - (1 - s) * (1 - np.exp(-np.arange(k) / (nd / 4))) / (1 - math.exp(-4))
    if nr and n > nr:
        e[-nr:] *= np.linspace(1, 0, nr)
    return e


def lowpass(x, a=0.1):
    """A one-pole low-pass (a: 0..1, smaller is darker)."""
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a * (x[i] - acc)
        y[i] = acc
    return y


def lp_fast(x, k=8):
    if k <= 1:
        return x
    c = np.cumsum(np.concatenate([[0.0], x]))
    out = (c[k:] - c[:-k]) / k
    return np.concatenate([out, np.full(k - 1, out[-1] if len(out) else 0.0)])


def sweep(f0, f1, n, kind="sq", duty=0.5, curve=1.0):
    t = np.linspace(0, 1, n) ** curve
    f = f0 + (f1 - f0) * t
    ph = np.cumsum(f) / SR
    if kind == "sq":
        return np.where((ph % 1) < duty, 1.0, -1.0)
    if kind == "sine":
        return np.sin(2 * math.pi * ph)
    if kind == "tri":
        return 2 * np.abs(2 * (ph % 1) - 1) - 1
    return 2 * (ph % 1) - 1


# ------------------------------------------------------------------------------------------- instruments

def inst(name, m, dur):
    n = max(1, int(dur * SR))
    f = midi(m)
    if name == "lead":
        return osc("sq", f, n, 0.25, vib=1) * env(n, 0.005, 0.12, 0.55, 0.03) * 0.5
    if name == "lead50":
        return osc("sq", f, n, 0.5, vib=1) * env(n, 0.005, 0.15, 0.5, 0.03) * 0.45
    if name == "tri":
        return osc("tri", f, n) * env(n, 0.005, 0.2, 0.7, 0.04)
    if name == "bass":
        return osc("sq", f, n, 0.125) * env(n, 0.003, 0.08, 0.6, 0.02) * 0.55
    if name == "tbass":
        return osc("tri", f, n) * env(n, 0.003, 0.1, 0.8, 0.03)
    if name == "bell":
        nn = int(0.6 * SR)
        x = (osc("sine", f, nn) + 0.4 * osc("sine", f * 2.01, nn) + 0.15 * osc("sine", f * 3.0, nn)) * np.exp(-tt(nn) * 6)
        return x * 0.5
    if name == "arp":
        return osc("sq", f, n, 0.25) * env(n, 0.002, 0.05, 0.3, 0.01) * 0.35
    if name == "organ":
        return (osc("sq", f, n, 0.5) * 0.5 + osc("sq", f * 2, n, 0.25) * 0.25) * env(n, 0.02, 0.3, 0.8, 0.1) * 0.5
    if name == "pad":
        x = sum(osc("sine", f * dt, n) for dt in (1.0, 1.003, 0.997)) / 3 + 0.25 * osc("sine", f * 2, n)
        return x * env(n, 0.25, 0.4, 0.85, 0.35) * 0.5
    if name == "choir":
        x = sum(osc("tri", f * dt, n, vib=1) for dt in (1.0, 1.005, 0.995, 2.0)) / 4
        return lp_fast(x, 4) * env(n, 0.3, 0.5, 0.9, 0.4) * 0.7
    if name == "brass":
        x = osc("saw", f, n, vib=1) * 0.6 + osc("sq", f, n, 0.3) * 0.3
        return lp_fast(x, 6) * env(n, 0.03, 0.2, 0.75, 0.06) * 0.55
    if name == "pluck":
        nn = int(0.5 * SR)
        return osc("tri", f, nn) * np.exp(-tt(nn) * 9) * 0.7
    raise ValueError(name)


def drum(name, vol=1.0):
    if name == "kick":
        n = int(0.18 * SR)
        return sweep(130, 40, n, "sine", curve=0.4) * np.exp(-tt(n) * 18) * vol
    if name == "snare":
        n = int(0.14 * SR)
        x = osc("noise", 0, n) * 0.8 + osc("tri", 190, n) * 0.4
        return x * np.exp(-tt(n) * 24) * vol * 0.7
    if name == "hat":
        n = int(0.04 * SR)
        x = osc("noise", 0, n)
        x = x - lp_fast(x, 3)
        return x * np.exp(-tt(n) * 80) * vol * 0.4
    if name == "timp":
        n = int(0.6 * SR)
        return sweep(95, 70, n, "sine") * np.exp(-tt(n) * 5) * vol
    raise ValueError(name)


# ------------------------------------------------------------------------------------------- songs

def place(buf, t, x, vol=1.0):
    i = int(t * SR)
    if i >= len(buf) or i + len(x) <= 0:
        return
    if i < 0:
        x = x[-i:]
        i = 0
    j = min(len(buf), i + len(x))
    buf[i:j] += x[: j - i] * vol


def song(buf, t0, t1, bpm, length, notes, drums=(), fade_in=0.05, fade_out=0.15, vol=1.0):
    """Loop `notes` [(beat, midi, beats, instrument, volume)] and `drums` [(beat, name, volume)] from t0 to t1."""
    part = np.zeros(int((t1 - t0 + 2) * SR))
    spb = 60.0 / bpm
    k = 0
    while k * length * spb < t1 - t0:
        base = k * length * spb
        for beat, m, beats, name, v in notes:
            t = base + beat * spb
            if t < t1 - t0:
                place(part, t, inst(name, m, beats * spb * 0.95), v)
        for beat, name, v in drums:
            t = base + beat * spb
            if t < t1 - t0:
                place(part, t, drum(name, v))
        k += 1
    n = int((t1 - t0) * SR)
    part = part[:n]
    fi, fo = int(fade_in * SR), int(fade_out * SR)
    if fi:
        part[:fi] *= np.linspace(0, 1, fi)
    if fo and fo < n:
        part[-fo:] *= np.linspace(1, 0, fo)
    place(buf, t0, part, vol)


def chord_arp(chords, beats_each, step, octave_notes, inst_name="arp", vol=0.3):
    out = []
    for ci, ch in enumerate(chords):
        b0 = ci * beats_each
        i = 0
        b = 0.0
        while b < beats_each - 1e-6:
            out.append((b0 + b, ch[i % len(ch)] + 12 * (i // len(ch) % octave_notes), step, inst_name, vol))
            b += step
            i += 1
    return out


def track(buf, name, t0, t1):
    if name == "wholesome":
        mel = [(0, 72, 1), (1, 76, 1), (2, 79, 1), (3, 76, 1), (4, 77, 1), (5, 81, 1), (6, 79, 2), (8, 76, 1), (9, 79, 1), (10, 84, 1), (11, 83, 1), (12, 81, 1), (13, 77, 1), (14, 79, 2)]
        notes = [(b, m, l, "tri", 0.22) for b, m, l in mel]
        notes += [(b, m, 2, "tbass", 0.28) for b, m in ((0, 48), (2, 55), (4, 53), (6, 55), (8, 48), (10, 52), (12, 53), (14, 55))]
        notes += [(b + 0.5, m, 0.5, "bell", 0.06) for b, m in zip(range(16), [84, 88, 91, 88] * 4)]
        song(buf, t0, t1, 96, 16, notes, [(b, "hat", 0.25) for b in range(16)], fade_in=0.4, vol=0.9)
    elif name == "boss":
        chords = [(69, 72, 76), (65, 69, 72), (67, 71, 74), (64, 68, 71)]
        roots = [45, 41, 43, 40]
        notes = chord_arp(chords, 4, 0.25, 2, "arp", 0.16)
        for ci, r in enumerate(roots):
            for e in range(8):
                notes.append((ci * 4 + e * 0.5, r + (12 if e % 2 else 0), 0.5, "bass", 0.32))
        mel = [(0, 81, 1.5), (1.5, 79, 0.5), (2, 76, 1), (3, 77, 1), (4, 77, 1.5), (5.5, 76, 0.5), (6, 72, 2), (8, 74, 1.5), (9.5, 72, 0.5), (10, 71, 1), (11, 74, 1), (12, 76, 3), (15, 68, 1)]
        notes += [(b, m, l, "lead", 0.22) for b, m, l in mel]
        dr = [(b, "kick", 0.9) for b in range(16)] + [(b, "snare", 0.8) for b in range(1, 16, 2)] + [(b * 0.5, "hat", 0.5) for b in range(32)]
        song(buf, t0, t1, 160, 16, notes, dr, vol=0.8)
    elif name == "villain":
        chords = [((50, 53, 57), 4), ((46, 50, 53), 2), ((45, 49, 52), 2)]
        notes = []
        b = 0
        for ch, l in chords:
            for m in ch:
                notes.append((b, m, l, "organ", 0.2))
            notes.append((b, ch[0] - 12, l, "tbass", 0.3))
            b += l
        notes += chord_arp([(62, 65, 69, 74)], 8, 0.5, 1, "pluck", 0.12)
        song(buf, t0, t1, 84, 8, notes, [(0, "timp", 0.8), (4, "timp", 0.6), (6, "timp", 0.5), (7, "timp", 0.5)], fade_in=0.3, vol=0.85)
    elif name == "build":
        # arpeggios that climb a step every bar, a kick that comes in, a riser over the top
        dur = t1 - t0
        bpm = 132
        spb = 60 / bpm
        bars = int(dur / (4 * spb)) + 1
        notes = []
        for bar in range(bars):
            ch = [69 + 2 * bar, 72 + 2 * bar, 76 + 2 * bar]
            notes += [(bar * 4 + n_[0], n_[1], n_[2], n_[3], n_[4]) for n_ in chord_arp([ch], 4, 0.25, 2, "arp", 0.16)]
            notes += [(bar * 4 + e * 0.5, 45 + 2 * bar, 0.5, "bass", 0.25) for e in range(8)]
        dr = [(b, "kick", 0.6 + 0.4 * min(1, b / 8)) for b in range(bars * 4)] + [(b + 0.5, "hat", 0.4) for b in range(bars * 4)]
        song(buf, t0, t1, bpm, bars * 4, notes, dr, vol=0.8)
        n = int(dur * SR)
        riser = sweep(200, 2400, n, "saw", curve=2) * np.linspace(0, 0.12, n)
        riser += osc("noise", 0, n) * np.linspace(0, 0.08, n)
        place(buf, t0, lp_fast(riser, 3))
    elif name == "battle":
        chords = [(72, 76, 79), (67, 71, 74), (69, 72, 76), (65, 69, 72)]
        roots = [48, 43, 45, 41]
        notes = chord_arp(chords, 4, 0.25, 2, "arp", 0.14)
        for ci, r in enumerate(roots):
            for e in range(8):
                notes.append((ci * 4 + e * 0.5, r + (12 if e % 2 else 0), 0.5, "bass", 0.3))
        mel = [(0, 84, 1), (1, 83, 0.5), (1.5, 84, 0.5), (2, 86, 2), (4, 83, 1.5), (5.5, 79, 0.5), (6, 81, 2), (8, 81, 1), (9, 79, 0.5), (9.5, 81, 0.5), (10, 84, 2), (12, 77, 1), (13, 79, 1), (14, 81, 1), (15, 83, 1)]
        notes += [(b, m, l, "lead50", 0.2) for b, m, l in mel]
        dr = [(b, "kick", 0.9) for b in range(16)] + [(b, "snare", 0.8) for b in range(1, 16, 2)] + [(b * 0.5, "hat", 0.5) for b in range(32)]
        song(buf, t0, t1, 168, 16, notes, dr, vol=0.8)
    elif name == "trailer":
        notes = [(0, 36, 8, "pad", 0.25), (0, 43, 8, "pad", 0.15), (4, 48, 4, "choir", 0.08)]
        song(buf, t0, t1, 60, 8, notes, fade_in=0.3, fade_out=0.4, vol=0.7)
    elif name == "drone":
        notes = [(0, 48, 8, "pad", 0.3), (0, 55, 8, "pad", 0.2), (0, 60, 8, "pad", 0.15), (4, 64, 4, "choir", 0.12)]
        song(buf, t0, t1, 60, 8, notes, fade_in=0.5, fade_out=0.3, vol=0.8)
    elif name == "finale":
        chords = [(60, 64, 67), (65, 69, 72), (67, 71, 74), (60, 64, 67, 72)]
        notes = []
        for ci, ch in enumerate(chords):
            for m in ch:
                notes.append((ci * 4, m, 4, "choir", 0.16))
            notes.append((ci * 4, ch[0] - 24, 4, "tbass", 0.3))
        mel = [(0, 72, 1.5), (1.5, 74, 0.5), (2, 76, 2), (4, 77, 1.5), (5.5, 76, 0.5), (6, 74, 2), (8, 79, 1.5), (9.5, 77, 0.5), (10, 76, 1), (11, 74, 1), (12, 72, 4)]
        notes += [(b, m, l, "brass", 0.26) for b, m, l in mel]
        notes += chord_arp(chords, 4, 0.25, 2, "arp", 0.08)
        dr = [(b, "kick", 1.0) for b in range(16)] + [(b, "snare", 0.9) for b in range(1, 16, 2)] + [(b * 0.5, "hat", 0.5) for b in range(32)] + [(b, "timp", 0.6) for b in (0, 4, 8, 12)]
        song(buf, t0, t1, 150, 16, notes, dr, fade_out=0.02, vol=0.85)
    elif name == "clean":
        chords = [(60, 64, 67, 71), (57, 60, 64, 67), (53, 57, 60, 64), (55, 59, 62, 67)]
        notes = []
        for ci, ch in enumerate(chords):
            for m in ch:
                notes.append((ci * 4, m, 4, "pad", 0.14))
            notes.append((ci * 4, ch[0] - 12, 4, "tbass", 0.22))
        mel = [(0, 76, 0.5), (0.5, 79, 0.5), (1, 84, 1), (2.5, 83, 0.5), (3, 79, 1), (4, 76, 0.5), (4.5, 79, 0.5), (5, 81, 1.5), (7, 79, 1), (8, 77, 0.5), (8.5, 81, 0.5), (9, 84, 1.5), (11, 83, 1), (12, 79, 1), (13, 81, 1), (14, 83, 2)]
        notes += [(b, m, l, "pluck", 0.22) for b, m, l in mel]
        dr = [(b, "kick", 0.55) for b in (0, 2, 4, 6, 8, 10, 12, 14)] + [(b + 0.5, "hat", 0.3) for b in range(16)]
        song(buf, t0, t1, 112, 16, notes, dr, fade_in=0.1, fade_out=0.6, vol=0.9)


# ------------------------------------------------------------------------------------------- sound effects

def sfx(name, **kw):
    if name == "pip":
        f = 1500 + 140 * (kw.get("n", 0) % 5)
        if kw.get("low"):
            f = 700 + 60 * (kw.get("n", 0) % 5)
        n = int(0.035 * SR)
        return osc("sq", f, n, 0.5) * np.exp(-tt(n) * 60) * 0.18
    if name == "blip":
        n = int(0.028 * SR)
        f = kw.get("f", 1200)
        x = osc("sq", f, n, 0.5)
        if kw.get("robot"):
            x *= osc("sq", 60, n, 0.5)
        return x * np.exp(-tt(n) * 40) * 0.09
    if name == "boom":
        s = kw.get("size", 1.0)
        n = int((0.5 + 0.5 * s) * SR)
        x = lp_fast(osc("noise", 0, n), 12) * 2.2 + sweep(90, 28, n, "sine") * 0.8
        return x * np.exp(-tt(n) * (6 / s)) * min(1.0, 0.45 + 0.45 * s)
    if name == "laser":
        n = int(0.25 * SR)
        return sweep(1600, 180, n, "sq", 0.5, curve=0.5) * np.exp(-tt(n) * 6) * 0.16
    if name == "crit":
        n = int(0.09 * SR)
        x = np.concatenate([osc("sq", 1568, n, 0.5), osc("sq", 2093, n, 0.5), osc("sq", 2637, 2 * n, 0.5) * np.exp(-tt(2 * n) * 10)])
        return x * 0.14
    if name == "siren":
        parts = [osc("sq", 760 if i % 2 == 0 else 1020, int(0.15 * SR), 0.5) for i in range(8)]
        return np.concatenate(parts) * 0.13
    if name == "whoosh":
        n = int(0.4 * SR)
        x = osc("noise", 0, n)
        x = lp_fast(x, 3) - lp_fast(x, 20)
        return x * np.sin(np.linspace(0, math.pi, n)) * 0.5
    if name == "chime":
        out = np.zeros(int(1.4 * SR))
        for i, m in enumerate((84, 88, 91, 96)):
            place(out, i * 0.07, inst("bell", m, 0.6), 0.5)
        return out
    if name == "buzzer":
        n = int(0.45 * SR)
        return (osc("sq", 110, n, 0.5) + osc("sq", 147, n, 0.5)) * env(n, 0.005, 0.1, 0.8, 0.05) * 0.1
    if name == "glitch":
        out = np.zeros(int(0.32 * SR))
        for i in range(10):
            seg_ = osc("sq", RNG.uniform(100, 3000), int(0.03 * SR), 0.5) if i % 2 else osc("noise", 0, int(0.03 * SR))
            place(out, i * 0.03, seg_, 0.14)
        return np.round(out * 6) / 6
    if name == "stamp":
        n = int(0.25 * SR)
        x = sweep(160, 50, n, "sine", curve=0.5) * np.exp(-tt(n) * 18) * 0.7 + lp_fast(osc("noise", 0, n), 4) * np.exp(-tt(n) * 40) * 0.4
        return x * (0.45 if kw.get("soft") else 0.8)
    if name == "step":
        n = int(0.3 * SR)
        return (sweep(70, 40, n, "sine") * 0.9 + lp_fast(osc("noise", 0, n), 20) * 0.6) * np.exp(-tt(n) * 14)
    if name == "achievement":
        out = np.zeros(int(1.0 * SR))
        for i, m in enumerate((72, 76, 79, 84, 88)):
            place(out, i * 0.07, osc("sq", midi(m), int(0.12 * SR), 0.25) * np.exp(-tt(int(0.12 * SR)) * 8), 0.14)
        place(out, 0.4, inst("bell", 96, 0.6), 0.25)
        return out
    if name == "powerup":
        n = int((0.35 if kw.get("short") else 0.7) * SR)
        x = sweep(220, 1800, n, "sq", 0.25, curve=1.5) * (0.6 + 0.4 * osc("sq", 18, n, 0.5))
        return x * env(n, 0.01, 0.3, 0.8, 0.05) * 0.13
    if name == "sparkle":
        out = np.zeros(int(0.6 * SR))
        for i, m in enumerate((96, 100, 103, 108)):
            place(out, i * 0.05, inst("bell", m, 0.3), 0.18)
        return out
    if name == "click":
        n = int(0.02 * SR)
        return osc("noise", 0, n) * np.exp(-tt(n) * 200) * 0.5
    if name == "powerdown":
        n = int(0.5 * SR)
        return sweep(900, 60, n, "sq", 0.5, curve=0.6) * np.exp(-tt(n) * 4) * 0.12
    if name == "wind":
        n = int(1.4 * SR)
        x = lp_fast(osc("noise", 0, n), 30)
        return x * (0.5 + 0.5 * np.sin(np.linspace(0, 3 * math.pi, n))) * np.sin(np.linspace(0, math.pi, n)) * 1.6
    if name == "clink":
        n = int(0.18 * SR)
        return (osc("sine", 3150, n) + 0.6 * osc("sine", 4230, n)) * np.exp(-tt(n) * 30) * 0.12
    if name == "pop":
        n = int(0.09 * SR)
        return sweep(1100, 220, n, "sine", curve=0.5) * np.exp(-tt(n) * 30) * 0.45
    if name == "rumble":
        n = int(1.2 * SR)
        return lp_fast(osc("noise", 0, n), 40) * np.linspace(0.2, 1.6, n) * 1.2
    if name == "tick":
        n = int(0.015 * SR)
        return osc("sq", 2400, n, 0.5) * np.exp(-tt(n) * 200) * (0.05 if kw.get("soft") else 0.09)
    if name == "alarm":
        n = int(0.12 * SR)
        return np.concatenate([osc("sq", 1320, n, 0.5), osc("sq", 990, n, 0.5)]) * 0.07
    if name == "sigh":
        n = int(0.7 * SR)
        x = osc("noise", 0, n)
        x = lp_fast(x, 6) - lp_fast(x, 30)
        return x * np.sin(np.linspace(0, math.pi, n)) * 0.25
    if name == "paper":
        n = int(0.15 * SR)
        x = osc("noise", 0, n)
        return (x - lp_fast(x, 4)) * np.exp(-tt(n) * 20) * 0.35
    if name == "grow":
        n = int(0.35 * SR)
        return sweep(250, 900, n, "sq", 0.5) * (0.5 + 0.5 * osc("sq", 24, n, 0.5)) * 0.12
    if name == "choir":
        out = np.zeros(int(1.6 * SR))
        for m in (60, 64, 67, 72):
            place(out, 0, inst("choir", m, 1.5), 0.3)
        return out
    if name == "fight":
        out = np.zeros(int(0.8 * SR))
        for m in (60, 67, 72, 76):
            place(out, 0, inst("brass", m, 0.6), 0.35)
        return out
    if name == "braam":
        n = int(1.3 * SR)
        x = sum(osc("saw", midi(m), n) for m in (31, 38, 43)) / 3
        x = lp_fast(x, 10) * env(n, 0.02, 0.6, 0.5, 0.3)
        return x * 0.55
    if name == "sizzle":
        n = int(0.8 * SR)
        x = osc("noise", 0, n)
        x = x - lp_fast(x, 2)
        crackle = (RNG.random(n) > 0.995) * RNG.uniform(-1, 1, n) * 3
        return (x * 0.25 + crackle * 0.3) * np.sin(np.linspace(0, math.pi, n)) * 0.6
    if name == "crunch":
        n = int(0.18 * SR)
        x = osc("noise", 0, n)
        return (x - lp_fast(x, 3)) * (RNG.random(n) > 0.6) * np.exp(-tt(n) * 18) * 0.7
    if name == "hit":
        n = int(0.12 * SR)
        return (osc("sq", 880, n, 0.5) * np.exp(-tt(n) * 20) * 0.14 + lp_fast(osc("noise", 0, n), 3) * np.exp(-tt(n) * 30) * 0.3)
    raise ValueError(name)


VOICE = {"gary": 1500, "tot": 1750, "tot (far away)": 1650, "cdo": 330, "dot": 760, "judge": 1100}


def mix(total, music, cues, says):
    buf = np.zeros(int((total + 1) * SR))
    for t0, t1, name in music:
        track(buf, name, t0, t1)
    fx = np.zeros_like(buf)
    for t, name, kw in cues:
        place(fx, t, sfx(name, **kw))
    for t0, t1, speaker, line, _ in says:
        f = VOICE.get(speaker, 1200)
        n = 0
        for i, ch in enumerate(line):
            if ch == " " or i % 2:
                continue
            tc = t0 + 0.08 + i / 28.0
            if tc > t1:
                break
            jitter = 1 + 0.04 * ((n * 7) % 5 - 2)
            place(fx, tc, sfx("blip", f=f * jitter, robot=speaker == "dot"), 0.35 if speaker == "tot (far away)" else 1.0)
            n += 1
    out = buf * 0.55 + fx
    out = np.tanh(out * 1.2) / np.tanh(1.2)
    peak = np.max(np.abs(out)) or 1.0
    out = out / peak * 0.89
    return out[: int(total * SR)]
