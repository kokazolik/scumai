import sys, os, subprocess
import numpy as np
from scipy.io import wavfile
from synth import *


def T(d):
    return np.arange(int(d * SR)) / SR


def place(buf, t, x, g=1.0):
    s = int(t * SR)
    e = min(len(buf), s + len(x))
    buf[s:e] += g * x[: e - s]


def metal(f0, d, partials=(1, 1.47, 2.09, 2.56, 3.37, 4.1, 5.2), dec=0.35):
    t = T(d)
    y = np.zeros(len(t))
    rng = np.random.default_rng(int(f0))
    for k, r in enumerate(partials):
        y += (0.9 ** k) * np.sin(2 * np.pi * f0 * r * (1 + rng.uniform(-.01, .01)) * t + rng.random() * 6) * np.exp(
            -t / (dec / (1 + 0.3 * k)))
    m = int(len(y) * 0.3)
    y[-m:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, m)))
    return y


def whoosh(d, f_from, f_to, peak_at=0.5, q=3.0):
    n = int(d * SR)
    x = noise(n)
    # time-varying bandpass via short blocks
    out = np.zeros(n)
    blk = 256
    t = np.arange(n) / n
    fc = f_from * (f_to / f_from) ** t
    env = np.where(t < peak_at, (t / peak_at) ** 2, ((1 - t) / (1 - peak_at)) ** 1.5)
    zi = None
    from scipy import signal as sg
    for i in range(0, n, blk):
        f = fc[i]
        b, a = sg.iirpeak(min(f, SR * 0.45), q, fs=SR)
        seg = x[i:i + blk]
        if zi is None:
            zi = sg.lfilter_zi(b, a) * 0
        y, zi = sg.lfilter(b, a, seg, zi=zi)
        out[i:i + blk] = y
    return out * env


def sword_hit():
    d = 0.6; y = np.zeros(int(d * SR))
    place(y, 0, metal(820, d, dec=0.25), 0.5)
    place(y, 0, metal(1370, d, dec=0.15), 0.3)
    t = T(0.08)
    place(y, 0, hp(noise(len(t)), 2000) * np.exp(-t / 0.012), 0.9)          # transient
    place(y, 0, frame_drum(1.0, 160, 70, 0.08), 0.7)                          # body thump
    place(y, 0.0, lp(noise(int(0.15 * SR)), 1500) * np.exp(-T(0.15) / 0.03), 0.5)
    return y


def miss_whoosh():
    return whoosh(0.38, 500, 2500, 0.55, 2.5) * 1.0 + 0.4 * whoosh(0.38, 300, 1200, 0.5, 2)


def crit():
    d = 1.0; y = np.zeros(int(d * SR))
    place(y, 0, whoosh(0.12, 800, 4000, 0.8, 2) , 0.6)
    place(y, 0.1, sword_hit(), 1.0)
    place(y, 0.1, metal(520, 0.9, dec=0.5), 0.35)
    place(y, 0.1, taiko(1.0, 140, 50, 0.25), 0.8)
    # rising shimmer
    for k, n in enumerate(("E6", "G#6", "B6", "E7")):
        place(y, 0.16 + k * 0.04, celesta(hz(n), 0.3, 0.6), 0.35)
    return y


def enemy_hit():
    d = 0.4; y = np.zeros(int(d * SR))
    place(y, 0, taiko(1.0, 150, 55, 0.12), 1.0)
    t = T(0.2)
    place(y, 0, bp(noise(len(t)), 200, 1800) * np.exp(-t / 0.035), 0.8)
    place(y, 0, lp(noise(len(t)), 400) * np.exp(-t / 0.06), 0.8)
    return y


def spell_cast():
    d = 1.1; t = T(d)
    f = 300 * (6 ** (np.clip(t / 0.6, 0, 1)))
    ph = 2 * np.pi * np.cumsum(f) / SR
    mod = np.sin(ph * 2.01) * (2.5 * np.exp(-t / 0.5))
    tone = np.sin(ph + mod) * np.clip(t / 0.05, 0, 1) * np.exp(-np.clip(t - 0.55, 0, None) / 0.15)
    y = 0.4 * tone
    y += 0.5 * whoosh(d, 400, 6000, 0.55, 1.5)
    rng = np.random.default_rng(4)
    for k in range(10):
        place(y, 0.3 + rng.uniform(0, 0.55), celesta(hz(rng.choice([84, 88, 91, 93, 96, 100])), 0.2, 0.4), 0.25)
    return y


def heal():
    d = 1.4; y = np.zeros(int(d * SR))
    for k, n in enumerate(("C5", "E5", "G5", "C6", "E6")):
        place(y, k * 0.07, bell(hz(n), 1, 0.7, partials=((1, 1, 0.9), (2, .3, .4), (3, .1, .2)), length=1.2), 0.5)
    pad = sum(strings(hz(n), 0.5, 0.5, att=0.2, rel=0.6, bright=3000) for n in ("C5", "G5", "E6"))
    place(y, 0.05, pad, 0.4)
    place(y, 0, whoosh(1.0, 1500, 7000, 0.3, 2) * 0.12)
    return y


def coin():
    d = 0.5; y = np.zeros(int(d * SR))
    ping = lambda f: metal(f, 0.45, partials=(1, 2.7, 5.1), dec=0.18)
    place(y, 0, ping(hz("B6")), 0.5)
    place(y, 0.07, ping(hz("E7")), 0.6)
    place(y, 0, hp(noise(200), 4000) * np.exp(-np.arange(200) / 30), 0.5)
    return y


def chest_open():
    d = 1.2; y = np.zeros(int(d * SR))
    # creak: sawtooth with wobbling low pitch through formant
    t = T(0.55)
    f = 90 + 40 * np.sin(2 * np.pi * 3.5 * t) + 60 * t
    cr = wt(f + 6 * noise(len(t)), saw_h(100, 6000), len(t))
    cr = peak(cr, 900, 4) + 0.6 * peak(cr, 2200, 5)
    cr *= np.clip(t / 0.05, 0, 1) * np.clip((0.55 - t) / 0.1, 0, 1)
    place(y, 0, cr, 0.35)
    place(y, 0.5, frame_drum(1.0, 120, 60, 0.12), 0.8)   # lid thunk
    place(y, 0.5, lp(noise(int(0.1 * SR)), 900) * np.exp(-T(0.1) / 0.02), 0.6)
    for k, n in enumerate(("G5", "B5", "D6", "G6", "B6")):
        place(y, 0.6 + k * 0.06, celesta(hz(n), 0.3, 0.6), 0.3)
    place(y, 0.6, whoosh(0.6, 3000, 9000, 0.2, 2), 0.2)
    return y


def level_up():
    d = 1.8; y = np.zeros(int(d * SR))
    seq = (("C5", 0, .12), ("E5", .1, .12), ("G5", .2, .12), ("C6", .3, .9))
    for n, t, du in seq:
        place(y, t, brass(hz(n), du, 0.9, 1.3), 0.45)
        place(y, t, celesta(hz(midi(n) + 12), du, 0.6), 0.3)
    for n in ("C5", "E5", "G5"):
        place(y, 0.3, strings(hz(n), 0.8, 0.6, att=0.05, rel=0.6, bright=3500), 0.25)
    place(y, 0.3, cymbal(0.7, 0, 0.6), 0.3)
    place(y, 0.3, timpani(hz("C3"), 0.8), 0.6)
    return y


def page():
    d = 0.16
    x = whoosh(d, 2500, 6000, 0.25, 1.2)
    t = T(d)
    x += 0.4 * hp(noise(len(t)), 3000) * np.exp(-t / 0.01)
    return x


def death_knell():
    d = 3.4; y = np.zeros(int(d * SR))
    toll = lambda f: bell(f, 2.5, 1, partials=((0.5, .6, 2.5), (1, 1, 2.0), (1.19, .5, 1.5), (1.5, .35, 1.2),
                                                (2.0, .3, 1.0), (2.51, .2, .7), (3.0, .1, .5)), length=3.0)
    place(y, 0, toll(hz("D4")), 0.6)
    place(y, 0.0, toll(hz("D3")), 0.3)
    place(y, 0.9, toll(hz("A3")), 0.45)
    place(y, 0, taiko(0.8, 80, 40, 1.0), 0.5)
    place(y, 0, strings(hz("D3"), 2.0, 0.6, att=0.4, rel=1.0, bright=900) + strings(hz("F3"), 2.0, 0.6, att=0.4, rel=1.0,
                                                                                    bright=900), 0.35)
    t = np.arange(len(y)) / SR
    return y * np.clip((d - t) / 0.6, 0, 1)


def flee():
    d = 0.9; y = np.zeros(int(d * SR))
    for k in range(6):
        tt = k * 0.11
        place(y, tt, frame_drum(0.7 - 0.08 * k, 200, 110, 0.04), 0.7)
        tn = T(0.05)
        place(y, tt, bp(noise(len(tn)), 800, 3000) * np.exp(-tn / 0.012), 0.35 - 0.04 * k)
    place(y, 0.05, whoosh(0.7, 1800, 400, 0.3, 2.5), 0.7)
    return y


SFX = dict(sword_hit=sword_hit, miss_whoosh=miss_whoosh, crit=crit, enemy_hit=enemy_hit, spell_cast=spell_cast,
           heal=heal, coin=coin, chest_open=chest_open, level_up=level_up, page=page, death_knell=death_knell,
           flee=flee)

LEVEL = dict(page=-14, coin=-6, miss_whoosh=-6, spell_cast=-5, heal=-3)

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, fn in SFX.items():
        x = fn()
        x = hp(x, 40)
        x -= x.mean()
        # trailing fade 15 ms + leading 1 ms
        f = int(0.015 * SR)
        x[-f:] *= np.linspace(1, 0, f)
        x[:32] *= np.linspace(0, 1, 32)
        pk_db = LEVEL.get(name, -1.0)
        x = x / np.max(np.abs(x)) * 10 ** (pk_db / 20)
        rms = 20 * np.log10(np.sqrt(np.mean(x ** 2)))
        wav = f"{out}/{name}.wav"
        wavfile.write(wav, SR, (x * 32767).astype(np.int16))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", "3",
                        f"{out}/{name}.ogg"], check=True)
        print(f"{name}: {len(x)/SR:.2f}s peak={pk_db}dB rms={rms:.1f}dB {os.path.getsize(f'{out}/{name}.ogg')//1024}KB")
