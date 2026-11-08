"""Tiny offline synth engine for loopable game music (numpy/scipy)."""
import numpy as np
from scipy import signal

SR = 32000
RNG = np.random.default_rng(1234)

NOTE_IDX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def midi(name):
    name = name.strip()
    base = NOTE_IDX[name[0].upper()]
    i = 1
    while i < len(name) and name[i] in "#b":
        base += 1 if name[i] == "#" else -1
        i += 1
    octv = int(name[i:])
    return 12 * (octv + 1) + base


def hz(n):
    if isinstance(n, str):
        n = midi(n)
    return 440.0 * 2 ** ((n - 69) / 12.0)


def parse(seq):
    """'B4:2 A4:1 r:1' -> [(name|None, units)]"""
    out = []
    for tok in seq.split():
        n, d = tok.split(":")
        out.append((None if n == "r" else n, float(d)))
    return out


# ---------------------------------------------------------------- helpers

def env_adsr(n, a, d, s, r, sr=SR, hold=None):
    """n total samples; note held for `hold` samples (default n - r)."""
    a_n = max(1, int(a * sr)); d_n = max(1, int(d * sr)); r_n = max(1, int(r * sr))
    if hold is None:
        hold = max(a_n + 1, n - r_n)
    e = np.empty(n)
    t = np.arange(n)
    e[:] = s
    m = t < a_n
    e[m] = (t[m] / a_n) ** 1.5 if a > 0.05 else t[m] / a_n
    m2 = (t >= a_n) & (t < a_n + d_n)
    e[m2] = 1 - (1 - s) * (t[m2] - a_n) / d_n
    # level at release start
    if hold < a_n:
        lvl = hold / a_n
    elif hold < a_n + d_n:
        lvl = 1 - (1 - s) * (hold - a_n) / d_n
    else:
        lvl = s
    m3 = t >= hold
    e[m3] = lvl * np.exp(-5.0 * (t[m3] - hold) / r_n)
    return e


def table(harm, size=4096):
    x = np.arange(size) / size
    tb = np.zeros(size)
    for k, a in enumerate(harm, 1):
        if a:
            tb += a * np.sin(2 * np.pi * k * x)
    return tb


def saw_h(f, limit=7000, maxh=80):
    n = int(min(maxh, max(1, limit // f)))
    return [((-1) ** (k + 1)) / k for k in range(1, n + 1)]


def sq_h(f, limit=7000, maxh=60):
    n = int(min(maxh, max(1, limit // f)))
    return [(1.0 / k if k % 2 else 0.0) for k in range(1, n + 1)]


def wt(freq, harm, n, phase0=None):
    """freq: scalar or array len n."""
    tb = table(harm)
    if np.isscalar(freq):
        freq = np.full(n, float(freq))
    ph = np.cumsum(freq) / SR
    ph += RNG.random() if phase0 is None else phase0
    ph = (ph % 1.0) * len(tb)
    i0 = ph.astype(int)
    fr = ph - i0
    i1 = (i0 + 1) % len(tb)
    return tb[i0] * (1 - fr) + tb[i1] * fr


def vibrato(n, f, rate=5.2, depth=0.005, delay=0.25):
    t = np.arange(n) / SR
    ramp = np.clip((t - delay) / 0.4, 0, 1)
    return f * (1 + depth * ramp * np.sin(2 * np.pi * rate * t + RNG.random() * 6))


def lp(x, fc, order=2):
    fc = min(fc, SR * 0.45)
    sos = signal.butter(order, fc, "low", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def hp(x, fc, order=2):
    sos = signal.butter(order, fc, "high", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def bp(x, lo, hi, order=2):
    hi = min(hi, SR * 0.45)
    sos = signal.butter(order, [lo, hi], "band", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def peak(x, fc, q=4.0):
    b, a = signal.iirpeak(fc, q, fs=SR)
    return signal.lfilter(b, a, x)


def noise(n):
    return RNG.standard_normal(n)


# ---------------------------------------------------------------- instruments
# every instrument: f(freq, dur_seconds, vel) -> mono np.array (may be longer than dur: release tail)

def pluck(f, dur, vel=1.0, bright=0.5, ring=1.5, body=True):
    """Karplus-Strong lute/harp."""
    total = int((dur + ring) * SR)
    P = int(np.ceil(SR / f))
    exc = noise(P)
    exc = lp(np.concatenate([exc, exc]), 800 + 6000 * bright)[P:]
    exc -= exc.mean()
    y = np.zeros(total + P + 2)
    y[1:P + 1] = exc
    # decay per period so that ~ -60 dB at `ring+dur` seconds for low notes, faster for high
    t60 = max(0.4, (dur + ring) * (1.0 if f < 400 else 400 / f * 1.0 + 0.2))
    g = 10 ** (-3 * P / (SR * t60))
    i = P + 1
    while i < len(y):
        j = min(i + P, len(y))
        L = j - i
        y[i:j] = g * 0.5 * (y[i - P:i - P + L] + y[i - P - 1:i - P - 1 + L])
        i = j
    y = y[1:]
    # retune: actual pitch SR/P -> f
    ratio = f / (SR / P)
    src = np.arange(0, len(y) - 1, ratio)
    y = np.interp(src, np.arange(len(y)), y)[:total]
    if len(y) < total:
        y = np.pad(y, (0, total - len(y)))
    if body:
        y = y + 0.6 * peak(y, 220, 3) + 0.4 * peak(y, 520, 3)
    # damp after dur + ring
    e = np.ones(total)
    tail = int(0.08 * SR)
    e[-tail:] = np.linspace(1, 0, tail)
    y = y * e
    y = y / (np.max(np.abs(y)) + 1e-9)
    return vel * y


def flute(f, dur, vel=1.0, breath=0.06, harm=(1, .22, .1, .05, .02)):
    n = int((dur + 0.25) * SR)
    fr = vibrato(n, f, 5.0, 0.006, 0.3)
    x = wt(fr, harm, n)
    br = bp(noise(n), f * 1.5, min(f * 4, 12000)) * breath
    e = env_adsr(n, 0.06, 0.1, 0.85, 0.2, hold=int(dur * SR))
    return vel * (x + br) * e


def fiddle(f, dur, vel=1.0):
    n = int((dur + 0.3) * SR)
    fr = vibrato(n, f, 5.6, 0.007, 0.18)
    x = wt(fr, saw_h(f, 9000), n)
    x = lp(x, 4200)
    x = 0.5 * x + 0.5 * (peak(x, 480, 2) + peak(x, 1150, 3) * 0.8 + peak(x, 2900, 3) * 0.6)
    e = env_adsr(n, 0.05, 0.15, 0.8, 0.22, hold=int(dur * SR))
    return vel * 0.5 * x * e


def reed(f, dur, vel=1.0):
    """accordion: two detuned reeds + tremolo"""
    n = int((dur + 0.15) * SR)
    h = [1, .7, .55, .4, .33, .25, .2, .15, .12, .1, .08, .06]
    h = h[: max(1, int(7000 // f))]
    x = wt(f * 2 ** (-6 / 1200), h, n) + wt(f * 2 ** (7 / 1200), h, n)
    x = lp(x, 3800)
    e = env_adsr(n, 0.025, 0.1, 0.85, 0.08, hold=int(dur * SR))
    return vel * 0.35 * x * e


def strings(f, dur, vel=1.0, att=0.45, rel=0.8, bright=2400, voices=3):
    n = int((dur + rel) * SR)
    x = np.zeros(n)
    for k in range(voices):
        det = (k - (voices - 1) / 2) * 7
        fr = vibrato(n, f * 2 ** (det / 1200), 4.8 + 0.4 * k, 0.004, 0.2)
        x += wt(fr, saw_h(f, 8000, 60), n)
    x = lp(x / voices, bright)
    x = x + 0.4 * peak(x, 700, 2)
    e = env_adsr(n, att, 0.3, 0.9, rel, hold=int(dur * SR))
    return vel * 0.6 * x * e


def staccato_str(f, dur, vel=1.0):
    n = int((dur + 0.12) * SR)
    x = wt(f * 2 ** (-5 / 1200), saw_h(f, 7000), n) + wt(f * 2 ** (5 / 1200), saw_h(f, 7000), n)
    x = lp(x, 2000)
    e = env_adsr(n, 0.008, 0.08, 0.55, 0.06, hold=int(dur * SR))
    return vel * 0.35 * x * e


def choir(f, dur, vel=1.0, vowel="a", att=0.7, rel=1.0):
    n = int((dur + rel) * SR)
    x = np.zeros(n)
    for k in range(3):
        det = (k - 1) * 9
        fr = vibrato(n, f * 2 ** (det / 1200), 5.0 + 0.3 * k, 0.006, 0.3)
        x += wt(fr, saw_h(f, 6000), n)
    forms = {"a": [(700, 1.0), (1220, 0.6), (2600, 0.25)], "o": [(450, 1.0), (800, 0.6), (2830, 0.15)],
             "u": [(325, 1.0), (700, 0.4), (2530, 0.1)]}[vowel]
    y = sum(a * peak(x, fc, 6) for fc, a in forms)
    y += 0.08 * bp(noise(n), 2000, 7000) * 0.3
    e = env_adsr(n, att, 0.3, 0.9, rel, hold=int(dur * SR))
    return vel * 0.5 * y * e


def brass(f, dur, vel=1.0, bright=1.0):
    n = int((dur + 0.25) * SR)
    fr = vibrato(n, f, 5.0, 0.004, 0.35)
    fr = fr * (1 - 0.01 * np.exp(-np.arange(n) / (0.03 * SR)))  # small scoop
    x = wt(fr, saw_h(f, 9000), n) * 0.5 + wt(fr * 1.002, saw_h(f, 9000), n) * 0.5
    dark = lp(x, 500 + f, 2)
    br = lp(x, (2200 + 2 * f) * bright, 2)
    t = np.arange(n) / SR
    ope = np.clip(0.35 + 0.65 * np.exp(-t / 0.25), 0, 1) * vel
    y = dark * (1 - ope) + br * ope
    e = env_adsr(n, 0.04, 0.2, 0.8, 0.18, hold=int(dur * SR))
    return vel * 0.6 * y * e


def bell(f, dur, vel=1.0, partials=((1, 1, 2.5), (2.0, .4, 1.2), (2.76, .35, .9), (5.4, .2, .45), (8.93, .1, .25)),
         length=None):
    length = length or max(dur, 2.5)
    n = int(length * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for r, a, d in partials:
        if f * r < SR * 0.45:
            y += a * np.sin(2 * np.pi * f * r * t + RNG.random()) * np.exp(-t / d)
    att = np.clip(t / 0.002, 0, 1)
    return vel * 0.5 * y * att


def musicbox(f, dur, vel=1.0):
    return bell(f, dur, vel, partials=((1, 1, 1.4), (3.0, .25, .3), (5.98, .12, .12), (4.07, .1, .2)), length=2.0)


def celesta(f, dur, vel=1.0):
    return bell(f, dur, vel, partials=((1, 1, 1.2), (2, .3, .5), (3, .12, .25), (4.2, .05, .15)), length=1.8)


def bass(f, dur, vel=1.0, decay=1.2):
    n = int((dur + 0.15) * SR)
    t = np.arange(n) / SR
    x = wt(f, [1, .5, .25, .12, .06, .03], n)
    x = lp(x, 900)
    e = env_adsr(n, 0.008, 0.05, 1.0, 0.12, hold=int(dur * SR)) * (0.55 + 0.45 * np.exp(-t / decay))
    return vel * 0.8 * x * e


def drone(f, dur, vel=1.0, cutoff=500, att=2.0, rel=2.0):
    n = int((dur + rel) * SR)
    x = np.zeros(n)
    for det in (-6, 0, 5):
        x += wt(vibrato(n, f * 2 ** (det / 1200), 0.2, 0.002, 0), saw_h(f, 4000), n)
    x = lp(x / 3, cutoff, 2)
    e = env_adsr(n, att, 0.5, 1.0, rel, hold=int(dur * SR))
    return vel * 0.7 * x * e


# ----- percussion

def frame_drum(vel=1.0, f0=150, f1=85, dec=0.28):
    n = int(0.6 * SR)
    t = np.arange(n) / SR
    fr = f1 + (f0 - f1) * np.exp(-t / 0.03)
    ph = 2 * np.pi * np.cumsum(fr) / SR
    x = np.sin(ph) * np.exp(-t / dec)
    x += 0.35 * bp(noise(n), 300, 2500) * np.exp(-t / 0.02)
    return vel * 0.9 * x


def taiko(vel=1.0, f0=110, f1=48, dec=0.55):
    n = int(1.3 * SR)
    t = np.arange(n) / SR
    fr = f1 + (f0 - f1) * np.exp(-t / 0.04)
    ph = 2 * np.pi * np.cumsum(fr) / SR
    x = np.sin(ph) * np.exp(-t / dec) + 0.3 * np.sin(2.3 * ph) * np.exp(-t / (dec * 0.4))
    x += 0.5 * lp(noise(n), 900) * np.exp(-t / 0.05)
    return vel * x


def snare(vel=1.0):
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    x = 0.7 * bp(noise(n), 900, 7000) * np.exp(-t / 0.08)
    x += 0.6 * np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05)
    return vel * x


def shaker(vel=1.0, dec=0.04):
    n = int(0.15 * SR)
    t = np.arange(n) / SR
    e = np.clip(t / 0.008, 0, 1) * np.exp(-t / dec)
    return vel * 0.4 * hp(noise(n), 5000) * e


def tamb(vel=1.0):
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    x = hp(noise(n), 6000)
    x = x + sum(peak(x, fc, 30) for fc in (7200, 8400, 9800))
    return vel * 0.25 * x * np.exp(-t / 0.07)


def timpani(f, vel=1.0, roll=0.0):
    n = int((2.5 + roll) * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    hits = [0.0] if roll <= 0 else list(np.arange(0, roll, 0.07))
    for i, h in enumerate(hits):
        s = int(h * SR)
        tt = t[: n - s]
        amp = 1.0 if roll <= 0 else (0.25 + 0.75 * (i / max(1, len(hits) - 1))) * 0.55
        z = np.zeros(n - s)
        for r, a, d in ((1, 1, .9), (1.5, .5, .6), (1.99, .35, .45), (2.44, .2, .3)):
            z += a * np.sin(2 * np.pi * f * r * tt + RNG.random() * 6) * np.exp(-tt / d)
        z += 0.4 * lp(noise(n - s), 600) * np.exp(-tt / 0.04)
        y[s:] += amp * z
    return vel * 0.6 * y


def cymbal(vel=1.0, swell=0.0, dec=1.6):
    n = int((swell + dec * 2.5) * SR)
    t = np.arange(n) / SR
    x = hp(noise(n), 4000) + 0.5 * bp(noise(n), 2500, 6000)
    if swell > 0:
        e = np.where(t < swell, (t / swell) ** 3, np.exp(-(t - swell) / dec))
    else:
        e = np.exp(-t / dec)
    return vel * 0.2 * x * e


def drip(f=1200, vel=1.0):
    n = int(0.25 * SR)
    t = np.arange(n) / SR
    fr = f * (1 + 1.2 * (1 - np.exp(-t / 0.03)))
    return vel * 0.4 * np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-t / 0.05)


# ---------------------------------------------------------------- mixing

class Mix:
    def __init__(self, length_s, loop=True, tail=0.0):
        self.loop = loop
        self.N = int(round(length_s * SR)) + (0 if loop else int(tail * SR))
        self.L = int(round(length_s * SR))
        self.dry = np.zeros((2, self.N))
        self.send = np.zeros((2, self.N))
        self.rng = np.random.default_rng(7)

    def add(self, t, sig, pan=0.0, gain=1.0, rev=0.25, jitter=0.0):
        if jitter:
            t += self.rng.uniform(-jitter, jitter)
        s = int(round(t * SR))
        th = (pan + 1) * np.pi / 4
        gl, gr = np.cos(th) * gain, np.sin(th) * gain
        for tgt, g in ((self.dry, 1 - rev * 0.5), (self.send, rev)):
            if g <= 0:
                continue
            self._put(tgt[0], s, sig * gl * g)
            self._put(tgt[1], s, sig * gr * g)

    def _put(self, buf, s, x):
        N = self.N
        if not self.loop:
            if s >= N:
                return
            e = min(N, s + len(x))
            buf[max(0, s):e] += x[max(0, -s): e - s]
            return
        s %= N
        pos = 0
        while pos < len(x):
            take = min(len(x) - pos, N - s)
            buf[s:s + take] += x[pos:pos + take]
            pos += take
            s = 0

    def render(self, rev_time=2.4, rev_lp=5000, predelay=0.02, wet=1.0):
        n = int(rev_time * 1.6 * SR)
        rng = np.random.default_rng(99)
        t = np.arange(n) / SR
        ir = np.zeros((2, n))
        pd = int(predelay * SR)
        for c in range(2):
            nz = rng.standard_normal(n)
            dark = lp(nz, rev_lp * 0.35)
            bright = lp(nz, rev_lp)
            d = np.exp(-6.9 * t / rev_time)
            ir[c] = (bright * np.exp(-6.9 * t / (rev_time * 0.45)) + 1.4 * dark * d)
            ir[c, :pd] = 0
            # early reflections
            for k in range(8):
                p = pd + int(rng.uniform(0.005, 0.06) * SR)
                ir[c, p] += rng.uniform(-1, 1) * 2
        ir /= np.sqrt(np.sum(ir ** 2, axis=1, keepdims=True))
        out = self.dry.copy()
        for c in range(2):
            w = signal.fftconvolve(self.send[c], ir[c])
            if self.loop:
                full = np.zeros(self.N)
                pos = 0
                while pos < len(w):
                    take = min(self.N, len(w) - pos)
                    full[:take] += w[pos:pos + take]
                    pos += take
                w = full
            else:
                w = w[: self.N]
            out[c] += wet * w * 0.9
        return out


def circ_filter(x, fn, warm=SR):
    """apply causal filter fn circularly so the loop point stays seamless."""
    pre = x[..., -warm:]
    y = fn(np.concatenate([pre, x], axis=-1))
    return y[..., warm:]


def master(x, loop=True, target_rms_db=-17.0, ceiling_db=-1.0):
    f = (lambda z: (lambda h: h + 0.35 * hp(h, 2500, 1))(hp(z, 42, 2)))
    if loop:
        x = np.stack([circ_filter(c, f) for c in x])
    else:
        x = np.stack([f(c) for c in x])
    x = x - x.mean(axis=1, keepdims=True)
    # rms normalise using the loudest 3-second windows (avoid quiet intros dominating)
    mono = x.mean(axis=0)
    w = 3 * SR
    rms_blocks = [np.sqrt(np.mean(mono[i:i + w] ** 2)) for i in range(0, max(1, len(mono) - w + 1), SR)]
    ref = np.percentile(rms_blocks, 75) if rms_blocks else np.sqrt(np.mean(mono ** 2))
    x = x * (10 ** (target_rms_db / 20) / (ref + 1e-12))
    # limiter (circular smoothing)
    ceil = 10 ** (ceiling_db / 20)
    pk = np.max(np.abs(x), axis=0)
    need = np.minimum(1.0, ceil / np.maximum(pk, 1e-9))
    win = int(0.01 * SR)
    if loop:
        padded = np.concatenate([need[-SR:], need, need[:SR]])
    else:
        padded = np.concatenate([np.ones(SR), need, np.ones(SR)])
    mn = -np.convolve(-padded, np.ones(1), "same")
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    mn = minimum_filter1d(padded, size=2 * win + 1)
    sm = uniform_filter1d(mn, size=2 * win + 1)
    sm = np.minimum(sm, mn * 0 + sm)
    g = sm[SR:SR + len(need)]
    x = x * g
    x = np.clip(x, -ceil, ceil)
    return x


def lfo(N, approx_period_s, phase=0.0):
    cycles = max(1, round(N / SR / approx_period_s))
    t = np.arange(N) / N
    return np.sin(2 * np.pi * cycles * t + phase)


def _tailfade(fn, frac=0.25):
    def w(*a, **k):
        y = fn(*a, **k)
        n = len(y)
        m = max(16, int(n * frac))
        y = y.copy()
        y[-m:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, m)))
        return y
    w.__name__ = fn.__name__
    return w


bell = _tailfade(bell)
musicbox = lambda f, dur, vel=1.0: bell(f, dur, vel, partials=((1, 1, 1.4), (3.0, .25, .3), (5.98, .12, .12), (4.07, .1, .2)), length=2.0)
celesta = lambda f, dur, vel=1.0: bell(f, dur, vel, partials=((1, 1, 1.2), (2, .3, .5), (3, .12, .25), (4.2, .05, .15)), length=1.8)
frame_drum = _tailfade(frame_drum)
taiko = _tailfade(taiko)
snare = _tailfade(snare)
shaker = _tailfade(shaker)
tamb = _tailfade(tamb)
timpani = _tailfade(timpani)
cymbal = _tailfade(cymbal)
drip = _tailfade(drip)
