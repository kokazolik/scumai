"""Procedural "dark fantasy tome" UI skin generator for «Хроники двоих».
All art is generated from math/noise here (no external assets).
Usage: python3 tools/gen_ui_skin.py art/ui   (needs numpy, pillow)
"""
import sys, os, math
import numpy as np
from PIL import Image

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
S = 4  # supersampling factor
RNG = np.random.default_rng(1337)

# ---------------------------------------------------------------- helpers

def hexc(h):
    h = h.lstrip('#')
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def grid(w, h):
    yy, xx = np.mgrid[0:h * S, 0:w * S].astype(np.float64)
    return (xx + 0.5) / S, (yy + 0.5) / S


def sd_rrect(x, y, x0, y0, x1, y1, r):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    qx, qy = np.abs(x - cx) - hx, np.abs(y - cy) - hy
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def sd_rrect_top(x, y, x0, y0, x1, y1, r):
    """rounded top corners, square bottom"""
    d1 = sd_rrect(x, y, x0, y0, x1, y1 + r * 2, r)
    return np.maximum(d1, y - y1)


def cov(d):
    """coverage from signed distance (px), 1px AA at supersample res"""
    return np.clip(0.5 - d * S, 0, 1)


def band(d, a, b):
    """coverage of region where a<=-d<=b (distance inside from edge)"""
    return np.clip(np.minimum((-d - a) * S + 0.5, (b + d) * S + 0.5), 0, 1)


def smooth(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def fbm_tile(w, h, beta=1.8, seed=0, lo=1.0):
    """periodic fractal noise via spectral synthesis (tileable by construction), 0..1"""
    rng = np.random.default_rng(seed)
    wn = rng.standard_normal((h, w))
    fy = np.fft.fftfreq(h)[:, None] * h
    fx = np.fft.fftfreq(w)[None, :] * w
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1
    amp = 1.0 / np.maximum(f, lo) ** beta
    amp[0, 0] = 0
    n = np.real(np.fft.ifft2(np.fft.fft2(wn) * amp))
    n = (n - n.mean()) / (n.std() + 1e-9)
    return n


def noise_for(w, h, period, margin, beta=1.8, seed=0, lo=1.0):
    """noise at supersample res for a 9-patch with given centre period (final px);
    periodic with that period so TILE stretching is seamless."""
    p = period * S
    t = fbm_tile(p, p, beta, seed, lo)
    ys = (np.arange(h * S) - margin * S) % p
    xs = (np.arange(w * S) - margin * S) % p
    return t[np.ix_(ys, xs)]


def normals(H):
    gy, gx = np.gradient(H)
    gx *= S
    gy *= S  # per final px
    nz = np.ones_like(H)
    n = np.stack([-gx, -gy, nz], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n


L = np.array([-0.45, -0.75, 0.6]); L /= np.linalg.norm(L)
HV = L + np.array([0, 0, 1.0]); HV /= np.linalg.norm(HV)


def light(H, spec_pow=40):
    n = normals(H)
    dif = np.clip((n * L).sum(-1), 0, 1)
    spec = np.clip((n * HV).sum(-1), 0, 1) ** spec_pow
    return dif, spec


def ramp(t, stops):
    """stops: list of (pos, '#hex')"""
    t = np.clip(t, 0, 1)
    pos = np.array([s[0] for s in stops])
    cols = np.array([hexc(s[1]) for s in stops])
    out = np.zeros(t.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(t, pos, cols[:, c])
    return out


GOLD = [(0.0, '#2a1505'), (0.25, '#6b4212'), (0.5, '#b07d26'), (0.72, '#e2b552'), (0.88, '#f8e08e'), (1.0, '#fffbe6')]
BRONZE = [(0.0, '#1c0f06'), (0.3, '#4a2e14'), (0.6, '#8a6030'), (0.85, '#c49a5a'), (1.0, '#f4dfae')]
SILVER = [(0.0, '#101216'), (0.3, '#3a3f4a'), (0.6, '#7d8594'), (0.85, '#c3cad6'), (1.0, '#ffffff')]


def metal(H, stops, base=0.18, k=0.62, spec=0.55, spec_pow=30):
    dif, sp = light(H, spec_pow)
    t = base + k * dif + spec * sp
    return ramp(t, stops)


class Canvas:
    def __init__(s, w, h):
        s.w, s.h = w, h
        s.rgb = np.zeros((h * S, w * S, 3))
        s.a = np.zeros((h * S, w * S))

    def over(s, col, alpha):
        alpha = np.clip(alpha, 0, 1)
        if np.ndim(col) == 1:
            col = np.broadcast_to(col, s.rgb.shape)
        na = alpha + s.a * (1 - alpha)
        s.rgb = (col * alpha[..., None] + s.rgb * (s.a * (1 - alpha))[..., None]) / np.maximum(na, 1e-6)[..., None]
        s.a = na

    def mul(s, f, mask=None):
        """darken/lighten existing colour (no alpha change)"""
        if mask is None:
            s.rgb = s.rgb * f[..., None] if np.ndim(f) else s.rgb * f
        else:
            ff = 1 + (f - 1) * mask
            s.rgb = s.rgb * ff[..., None]

    def save(s, name, dither=True):
        rgb = s.rgb.reshape(s.h, S, s.w, S, 3).mean((1, 3))
        a = s.a.reshape(s.h, S, s.w, S).mean((1, 3))
        img = np.dstack([np.clip(rgb, 0, 1), np.clip(a, 0, 1)]) * 255
        if dither:  # break banding
            img[..., :3] += RNG.uniform(-0.5, 0.5, img[..., :3].shape)
        img = np.clip(np.round(img), 0, 255).astype(np.uint8)
        im = Image.fromarray(img, 'RGBA')
        p = os.path.join(OUT, name)
        im.save(p, optimize=True)
        print(name, im.size, os.path.getsize(p))


def dome(d, a, b, height=1.0):
    """rounded bead profile for -d in [a,b]"""
    t = np.clip(((-d) - a) / (b - a), 0, 1)
    return np.sqrt(np.clip(1 - (2 * t - 1) ** 2, 0, 1)) * (b - a) * 0.5 * height


# ---------------------------------------------------------------- leather / stone fill

def leather(x, y, w, h, period, margin, seed, base='#2b1e16', dark='#120b07', light_c='#4a3324', relief=0.5):
    n1 = noise_for(w, h, period, margin, beta=2.2, seed=seed, lo=2)  # mottling
    n2 = noise_for(w, h, period, margin, beta=0.9, seed=seed + 1, lo=6)  # pebble grain
    t = 0.5 + 0.085 * n1 + 0.075 * n2
    col = ramp(t, [(0, dark), (0.5, base), (1, light_c)])
    # pebble relief lighting
    Hh = n2 * 0.22 * relief + n1 * 0.2 * relief
    dif, _ = light(Hh)
    col *= (0.86 + 0.28 * dif)[..., None]
    return col


def parchment(x, y, w, h, period, margin, seed):
    n1 = noise_for(w, h, period, margin, beta=2.4, seed=seed, lo=1.5)
    n2 = noise_for(w, h, period, margin, beta=1.2, seed=seed + 7, lo=4)
    n3 = noise_for(w, h, period, margin, beta=0.6, seed=seed + 9, lo=20)
    t = 0.55 + 0.11 * n1 + 0.035 * n2 + 0.02 * n3
    col = ramp(t, [(0, '#a8834f'), (0.35, '#d2b27a'), (0.6, '#e6cf9f'), (0.85, '#f1e2bd'), (1, '#f8eed2')])
    # faint stains
    st = smooth(1.2, 2.2, n1)
    col *= (1 - 0.07 * st)[..., None]
    return col


# ---------------------------------------------------------------- panels

def rivet(x, y, cx, cy, r):
    d = np.hypot(x - cx, y - cy)
    m = cov(d - r)
    Hh = np.sqrt(np.clip(1 - (d / r) ** 2, 0, 1)) * r * 0.9
    return m, Hh


def diamond(x, y, cx, cy, rx, ry):
    d = (np.abs(x - cx) / rx + np.abs(y - cy) / ry - 1) * min(rx, ry) / 1.4
    return d


def make_panel_dark(name='panel_dark.png', W=160, M=44, seed=10, guards=True):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    r = 14
    d = sd_rrect(x, y, 0.5, 0.5, w - 0.5, h - 0.5, r)
    shape = cov(d)
    fill = leather(x, y, w, h, W - 2 * M, M, seed)
    c.over(fill, shape)
    # inner shadow / edge darkening (inside the inner gold line)
    ish = smooth(26, 8, -d)
    c.mul(1 - 0.55 * ish, shape)
    # soft top light
    c.mul(1.0 + 0.10 * smooth(h, 0, y) - 0.05)
    # outline
    c.over(hexc('#0b0604'), band(d, 0, 1.6))
    # main gold rim (hammered)
    hn = noise_for(w, h, W - 2 * M, M, beta=0.8, seed=seed + 3, lo=8) * 0.10
    H = dome(d, 1.4, 6.2, 1.2) + hn
    c.over(metal(H, GOLD), band(d, 1.4, 6.2))
    # thin inner line
    H2 = dome(d, 9.0, 10.8, 1.0)
    c.over(metal(H2, GOLD, base=0.25), band(d, 9.0, 10.8))
    # dark between lines
    c.over(hexc('#0e0805'), band(d, 6.2, 7.0) * 0.8)
    if guards:
        # corner guards
        fx = np.where(x > w / 2, w - x, x)
        fy = np.where(y > h / 2, h - y, y)
        L_ = 27.0
        sdu = sd_rrect(fx, fy, -12, -12, 19, 19, 5)
        for (ax_, ay_) in ((fx, fy), (fy, fx)):
            arm = np.maximum.reduce([ax_ - L_, -ax_, ay_ - 10.5])
            knob = np.hypot(ax_ - L_, ay_ - 5.5) - 5.2
            tip = diamond(ax_, ay_, L_ + 7.5, 5.5, 6.5, 2.6)
            sdu = np.minimum.reduce([sdu, arm, knob, tip])
        sd = np.maximum(sdu, d + 0.9)
        gm = cov(sd)
        shd = np.clip(cov(sd - 2.2) - gm, 0, 1)
        c.over(np.zeros(3), shd * 0.7 * shape)
        Hg = np.clip(-sd, 0, 2.6) * 1.0 + hn * 1.5
        Hg -= band(sd, 3.0, 3.8) * 0.9
        c.over(metal(Hg, GOLD, base=0.12, k=0.7), gm)
        rm, rh = rivet(fx, fy, 9.0, 9.0, 3.6)
        c.over(np.zeros(3), cov(np.hypot(fx - 9.6, fy - 9.6) - 4.4) * 0.5)
        c.over(metal(rh, GOLD, base=0.1, k=0.75, spec=0.9), rm)
    else:
        pass
    c.save(name)


def make_panel_inset(name='panel_inset.png', W=96, M=22, seed=40, base='#1f1611'):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    d = sd_rrect(x, y, 0.5, 0.5, w - 0.5, h - 0.5, 10)
    shape = cov(d)
    fill = leather(x, y, w, h, W - 2 * M, M, seed, base=base, dark='#0d0806', light_c='#3a281c', relief=0.35)
    c.over(fill, shape)
    c.mul(1 - 0.5 * smooth(14, 2, -d), shape)
    c.over(hexc('#090504'), band(d, 0, 1.4))
    H = dome(d, 1.3, 3.6, 1)
    c.over(metal(H, BRONZE, base=0.25), band(d, 1.3, 3.6))
    c.save(name)


def make_parchment(name='panel_parchment.png', W=192, M=48, seed=21):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    # slightly irregular (periodic) edge
    en = noise_for(w, h, W - 2 * M, M, beta=1.6, seed=seed + 2, lo=6)
    d0 = sd_rrect(x, y, 2, 2, w - 2, h - 2, 9)
    d = d0 + en * 0.45
    shape = cov(d)
    col = parchment(x, y, w, h, W - 2 * M, M, seed)
    c.over(col, shape)
    # burnt / aged edges
    burn = smooth(22, 0, -d + en * 3)
    c.mul(1 - 0.42 * burn ** 1.4, shape)
    edge = smooth(4, 0, -d)
    c.rgb = c.rgb * (1 - edge * 0.25)[..., None] + hexc('#5a3413') * (edge * 0.25)[..., None]
    # ink double frame line
    ink = hexc('#5b3a1e')
    c.over(ink, band(d0, 11, 12.6) * 0.75)
    c.over(ink, band(d0, 15, 15.9) * 0.55)
    # corner ink flourishes: small diamond + dots in each corner
    fx = np.where(x > w / 2, w - x, x)
    fy = np.where(y > h / 2, h - y, y)
    dd = diamond(fx, fy, 13.5, 13.5, 4.6, 4.6)
    c.over(hexc('#7a4a1c'), cov(dd) * 0.85)
    dd2 = diamond(fx, fy, 13.5, 13.5, 2.0, 2.0)
    c.over(hexc('#e6c37a'), cov(dd2) * 0.8)
    for (px, py) in ((22.5, 13.5), (13.5, 22.5)):
        c.over(ink, cov(np.hypot(fx - px, fy - py) - 1.3) * 0.7)
    # outer darkest rim
    c.over(hexc('#3a2210'), band(d, 0, 1.2) * 0.8)
    c.save(name)


# ---------------------------------------------------------------- buttons

BTN = {
    'gold': dict(face=[(0, '#7a4c10'), (0.45, '#c88d22'), (0.75, '#efc35a'), (1, '#fff0b0')], rim=BRONZE, spec=0.5),
    'dark': dict(face=[(0, '#0f0a08'), (0.45, '#2a1f19'), (0.8, '#46362b'), (1, '#6a5544')], rim=GOLD, spec=0.25),
    'red': dict(face=[(0, '#3a0606'), (0.45, '#7e1212'), (0.78, '#b52a20'), (1, '#e46a4a')], rim=GOLD, spec=0.35),
    'green': dict(face=[(0, '#0b2209'), (0.45, '#1f5418'), (0.78, '#3a8a2a'), (1, '#86c766')], rim=GOLD, spec=0.35),
    'blue': dict(face=[(0, '#06142e'), (0.45, '#163a7a'), (0.78, '#2e64b4'), (1, '#7fb0ee')], rim=GOLD, spec=0.35),
    'purple': dict(face=[(0, '#1a0a2a'), (0.45, '#45206e'), (0.78, '#7040a8'), (1, '#b48ae0')], rim=GOLD, spec=0.35),
}


def make_button(kind, pressed=False, W=128, Hh=88):
    p = BTN[kind]
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    r = 14
    d = sd_rrect(x, y, 0.5, 0.5, w - 0.5, h - 0.5, r)
    shape = cov(d)
    # face: pillow-shaped height (smooth, stretch-safe), light from top
    rim_out, rim_in = 1.3, 5.3
    df = d + rim_in
    # vertical gradient + bevel near the rim edge
    vy = (y - rim_in) / (h - 2 * rim_in)
    t = 0.82 - 0.5 * vy
    if pressed:
        t = 0.55 - 0.2 * vy
    # top gloss band
    gloss = smooth(0.0, 0.08, vy) * smooth(0.48, 0.30, vy)
    t = t + (0.10 if not pressed else 0.0) * gloss
    # bevel: edge highlight on top inner edge, shadow on bottom
    bev = smooth(6, 0, -df)
    up = np.clip(-(y - h / 2) / (h / 2), -1, 1)
    if not pressed:
        t = t + bev * 0.22 * up
    else:
        pass
    gn = noise_for(w, h, w - 60, 30, beta=1.1, seed=sum(map(ord, kind)), lo=6)
    t = t + (0.010 if kind == 'gold' else 0.018) * gn
    face = ramp(t, p['face'])
    c.over(face, shape)
    # inner shadow line just inside the rim
    c.over(np.zeros(3), band(d, rim_in, rim_in + 1.4) * (0.55 if not pressed else 0.75))
    if not pressed:
        c.over(np.ones(3), band(d, rim_in + 1.4, rim_in + 2.4) * smooth(h * 0.6, 0, y) * 0.18)
    if pressed:
        ish = np.exp(-np.clip(-df, 0, None) / 4.0) * (0.25 + 0.35 * smooth(h * 0.7, 0, y))
        c.over(np.zeros(3), ish * shape)
    # outer outline + metal rim
    c.over(hexc('#0a0503'), band(d, 0, rim_out + 0.3))
    Hr = dome(d, rim_out, rim_in, 1.25)
    c.over(metal(Hr, p['rim'], base=0.12 if not pressed else 0.05, k=0.7 if not pressed else 0.55), band(d, rim_out, rim_in))
    c.save(f'button_{kind}{"_pressed" if pressed else ""}.png')


# ---------------------------------------------------------------- slots

def make_slot(name, glow=None, W=96, seed=50):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    d = sd_rrect(x, y, 0.5, 0.5, w - 0.5, h - 0.5, 12)
    shape = cov(d)
    fill = leather(x, y, w, h, W - 56, 28, seed, base='#18110d', dark='#070403', light_c='#2c2017', relief=0.3)
    c.over(fill, shape)
    # recessed: strong inner shadow, darker at top (light from above => top inner wall shadowed)
    rim_in = 5.5
    di = -(d + rim_in)
    ish = smooth(16, 0, di)
    c.mul(1 - 0.75 * ish * (0.6 + 0.4 * smooth(h, 0, y)), shape)
    # lit bottom inner lip
    lip = band(d, rim_in, rim_in + 1.5) * smooth(h * 0.5, h, y)
    c.over(hexc('#6a5038'), lip * 0.6)
    if glow is not None:
        gc = hexc(glow)
        g = np.exp(-np.clip(di, 0, None) / 7.0) * shape * (di > -0.5)
        c.rgb = c.rgb + (gc * 0.85)[None, None, :] * g[..., None] * 0.9
        # centre faint radial glow
        rc = np.hypot(x - w / 2, y - h / 2) / (w / 2)
        c.rgb = c.rgb + gc[None, None, :] * (0.10 * np.clip(1 - rc, 0, 1) ** 1.5)[..., None] * shape[..., None]
    c.over(hexc('#0a0503'), band(d, 0, 1.4))
    Hr = dome(d, 1.3, rim_in, 1.2)
    if glow is None:
        c.over(metal(Hr, GOLD, base=0.1, k=0.65), band(d, 1.3, rim_in))
    else:
        gcol = metal(Hr, GOLD, base=0.15, k=0.65)
        gc = hexc(glow)
        tint = gcol * 0.45 + (gc * 0.55 + 0.25 * gcol)
        c.over(np.clip(tint, 0, 1), band(d, 1.3, rim_in))
    # corner studs
    fx = np.where(x > w / 2, w - x, x)
    fy = np.where(y > h / 2, h - y, y)
    rm, rh = rivet(fx, fy, 6.3, 6.3, 2.6)
    c.over(metal(rh, GOLD, base=0.1, k=0.75, spec=0.9), rm)
    c.save(name)


# ---------------------------------------------------------------- tabs

def make_tab(name, on, W=128, Hh=72):
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    d = sd_rrect_top(x, y, 0.5, 0.5, w - 0.5, h, 14)
    shape = cov(d)
    vy = y / h
    if on:
        face = ramp(0.85 - 0.55 * vy + 0.12 * smooth(0.0, 0.1, vy) * smooth(0.5, 0.3, vy),
                    [(0, '#2a0808'), (0.45, '#6a1612'), (0.8, '#a53424'), (1, '#e07a52')])
    else:
        face = ramp(0.7 - 0.45 * vy, [(0, '#0c0806'), (0.5, '#221914'), (1, '#3e3027')])
    c.over(face, shape)
    rim_in = 4.5 if on else 3.5
    c.over(np.zeros(3), band(d, rim_in, rim_in + 1.2) * 0.5)
    c.over(hexc('#0a0503'), band(d, 0, 1.4))
    Hr = dome(d, 1.3, rim_in, 1.2)
    c.over(metal(Hr, GOLD if on else BRONZE, base=0.12 if on else 0.05, k=0.7 if on else 0.5), band(d, 1.3, rim_in))
    if on:
        # gold underline glow at bottom
        c.over(hexc('#ffd77a'), cov(np.abs(y - (h - 2.5)) - 1.6) * shape)
        c.over(hexc('#ffb840'), smooth(10, 0, h - y) * 0.25 * shape)
    else:
        c.over(hexc('#5a4430'), cov(np.abs(y - (h - 1.0)) - 1.0) * shape)
    c.save(name)


# ---------------------------------------------------------------- bars

def make_bar_bg(name='bar_bg.png', W=96, Hh=32):
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    d = sd_rrect(x, y, 0.5, 0.5, w - 0.5, h - 0.5, h / 2 - 0.5)
    shape = cov(d)
    groove = ramp(0.2 + 0.25 * (y / h), [(0, '#050302'), (1, '#2a1d16')])
    c.over(groove, shape)
    c.mul(1 - 0.6 * smooth(8, 3, -d) * smooth(h, 0, y), shape)
    c.over(hexc('#0a0503'), band(d, 0, 1.2))
    Hr = dome(d, 1.1, 3.6, 1.2)
    c.over(metal(Hr, GOLD, base=0.12, k=0.7), band(d, 1.1, 3.6))
    c.save(name)


def make_bar_fill(name, stops, W=96, Hh=32, inset=3.6):
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    d = sd_rrect(x, y, inset, inset, w - inset, h - inset, (h - 2 * inset) / 2)
    shape = cov(d)
    vy = (y - inset) / (h - 2 * inset)
    t = 0.78 - 0.55 * vy
    face = ramp(t, stops)
    c.over(face, shape)
    # glossy gem highlight: bright band at top third
    gl = smooth(0.05, 0.18, vy) * smooth(0.48, 0.25, vy) * smooth(0, 4, -d)
    c.over(np.ones(3), gl * 0.38)
    # inner bottom glow (refraction)
    c.over(ramp(np.ones_like(vy), stops), smooth(0.7, 0.95, vy) * smooth(0, 3, -d) * 0.35)
    c.over(np.zeros(3), band(d, 0, 1.0) * 0.45)
    c.save(name)


# ---------------------------------------------------------------- divider / ribbon / frame

def make_divider(name='divider.png', W=640, Hh=40):
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    cx, cy = w / 2, h / 2
    ax = np.abs(x - cx)
    # tapering line: thickness from 3.2 at centre to 0 at ends
    t = np.clip(1 - ax / (w / 2 - 6), 0, 1)
    thick = 0.4 + 2.2 * t ** 0.7
    dl = np.abs(y - cy) - thick / 2
    line_m = cov(dl) * smooth(0, 0.04, t)
    # second thinner lines above/below near centre
    thin = 0.35 + 0.6 * t
    for off in (-5.5, 5.5):
        dl2 = np.abs(y - cy - off) - thin / 2
        m2 = cov(dl2) * smooth(0.45, 0.75, t) * cov(ax - 150)
        line_m = np.maximum(line_m, m2 * 0.9)
    # central diamond + side circles + scroll curls
    dd = diamond(x, y, cx, cy, 13, 11)
    dd_in = diamond(x, y, cx, cy, 6.5, 5.5)
    shape_sd = dd
    for sx in (-1, 1):
        # small diamonds
        shape_sd = np.minimum(shape_sd, diamond(x, y, cx + sx * 26, cy, 5.5, 4.2))
        # ring curls
        rr = np.hypot(x - (cx + sx * 44), y - cy)
        shape_sd = np.minimum(shape_sd, np.abs(rr - 5) - 1.3)
        # leaf ends
        shape_sd = np.minimum(shape_sd, diamond(x, y, cx + sx * 60, cy, 9, 2.6))
    m = np.maximum(line_m, cov(shape_sd))
    # height for shading
    Hh_ = np.clip(-shape_sd, 0, 3) + np.clip(-dl, 0, 1.5)
    col = metal(Hh_ * 1.2, GOLD, base=0.3, k=0.6)
    # dark shadow under
    shadow = np.maximum(cov(np.abs(y - cy - 1.5) - thick / 2 - 0.8) * smooth(0, 0.04, t), cov(shape_sd - 1.5))
    c.over(np.zeros(3), shadow * 0.6)
    c.over(col, m)
    # ruby in centre
    c.over(ramp(0.3 + 0.7 * smooth(cy + 6, cy - 6, y), [(0, '#3a0505'), (0.6, '#b01818'), (1, '#ff8a70')]), cov(dd_in))
    c.over(np.ones(3), cov(np.hypot(x - cx + 1.5, y - cy + 1.8) - 1.3) * 0.8)
    c.save(name)


def make_ribbon(name='header_ribbon.png', W=560, Hh=104):
    w, h = W, Hh
    x, y = grid(w, h)
    c = Canvas(w, h)
    # tails (behind), folded ends with V notch
    top, bot = 22, h - 10
    tail_top, tail_bot = 36, h - 2
    for side in (-1, 1):
        xs = x if side < 0 else (w - x)
        # tail rect from 0..70 (in xs)
        tail = np.maximum.reduce([tail_top - y, y - tail_bot, xs - 74, -xs])
        # V notch
        midy = (tail_top + tail_bot) / 2
        notch = 18 - xs - np.abs(y - midy) * 0.9
        tail = np.maximum(tail, notch)
        tm = cov(tail)
        tcol = ramp(0.22 + 0.45 * smooth(tail_bot, tail_top, y), [(0, '#1e0303'), (0.5, '#4e0a0a'), (1, '#7a1a14')])
        tcol = tcol * (1 - 0.55 * smooth(40, 74, xs))[..., None]  # shadow where it tucks behind
        c.over(tcol, tm)
        # gold edges top & bottom only
        eg = np.minimum(np.abs(y - (tail_top + 4)), np.abs(y - (tail_bot - 4))) - 1.4
        c.over(metal(np.clip(-eg, 0, 1.4), GOLD, base=0.25, k=0.6), cov(eg) * tm * (1 - 0.6 * smooth(40, 74, xs)))
        c.over(hexc('#0a0202'), band(tail, 0, 1.0) * tm)
    # main band
    band_sd = np.maximum.reduce([top - y, y - bot, 60 - x, x - (w - 60)])
    # slight curve
    curve = 3.0 * ((x - w / 2) / (w / 2)) ** 2
    band_sd = np.maximum.reduce([top - curve - y, y - (bot - curve), 60 - x, x - (w - 60)])
    m = cov(band_sd)
    vy = (y - top + curve) / (bot - top)
    nz = noise_for(w, h, 64, 0, beta=1.0, seed=77, lo=10)
    face = ramp(0.75 - 0.5 * vy + 0.1 * smooth(0.05, 0.15, vy) * smooth(0.5, 0.3, vy) + 0.02 * nz,
                [(0, '#2a0404'), (0.45, '#6e1010'), (0.8, '#a52a1e'), (1, '#d8604a')])
    c.over(face, m)
    # gold borders top/bottom
    for yy0 in (0,):
        pass
    db_top = np.abs(y - (top - curve + 4)) - 2.2
    db_bot = np.abs(y - (bot - curve - 4)) - 2.2
    gm = np.maximum(cov(db_top), cov(db_bot)) * m
    Hg = np.clip(-np.minimum(db_top, db_bot), 0, 2.2) * 1.2
    c.over(metal(Hg, GOLD, base=0.2, k=0.7), gm)
    # edges outline
    c.over(hexc('#0a0202'), band(band_sd, 0, 1.0) * m)
    c.save(name)


def make_portrait_frame(name='portrait_frame.png', W=160):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    cx, cy = w / 2, h / 2
    rr = np.hypot(x - cx, y - cy)
    R_out, R_in = 76, 62
    ring = np.maximum(rr - R_out, R_in - rr)
    mid = (R_out + R_in) / 2
    # outer dark outline
    c.over(hexc('#0a0503'), cov(np.maximum(rr - R_out - 1.5, R_in - 1.5 - rr)))
    # hammered gold ring with an engraved groove
    hn = fbm_tile(w * S, h * S, 0.8, 91, 10) * 0.12
    Hh_ = np.sqrt(np.clip(1 - ((rr - mid) / ((R_out - R_in) / 2)) ** 2, 0, 1)) * 5 + hn
    Hh_ -= cov(np.abs(rr - mid) - 0.8) * 1.4
    c.over(metal(Hh_, GOLD, base=0.12, k=0.7), cov(ring))
    # inner thin bronze ring
    c.over(metal(np.sqrt(np.clip(1 - ((rr - (R_in - 2.5)) / 1.6) ** 2, 0, 1)) * 1.5, BRONZE, base=0.2), cov(np.abs(rr - (R_in - 2.5)) - 1.6))
    # gems at 4 points
    ang = np.arctan2(y - cy, x - cx)
    for k, (gx, gy) in enumerate([(cx, cy + mid), (cx, cy - mid), (cx - mid, cy), (cx + mid, cy)]):
        rad = 8.5 if k == 0 else 5.5
        dg = np.hypot(x - gx, y - gy)
        # gold bezel
        c.over(hexc('#0a0503'), cov(dg - rad - 3.2))
        c.over(metal(np.sqrt(np.clip(1 - ((dg - rad - 1.2) / 2.2) ** 2, 0, 1)) * 2, GOLD, base=0.25), cov(dg - rad - 2.6))
        gt = 0.25 + 0.75 * smooth(gy + rad, gy - rad, y) * 0.7 + 0.3 * smooth(rad, 0, dg)
        stops = [(0, '#2a0404'), (0.55, '#b3171a'), (0.85, '#ff5a4a'), (1, '#ffd0c0')] if k == 0 else \
            [(0, '#05152a'), (0.55, '#1f5fb0'), (0.85, '#5ab0ff'), (1, '#e0f4ff')]
        c.over(ramp(gt, stops), cov(dg - rad))
        c.over(np.ones(3), cov(np.hypot(x - gx + rad * 0.35, y - gy + rad * 0.4) - rad * 0.22) * 0.85)
    c.save(name)


def make_portrait_bg(name='portrait_bg.png', W=160):
    w = h = W
    x, y = grid(w, h)
    c = Canvas(w, h)
    cx, cy = w / 2, h / 2
    rr = np.hypot(x - cx, y - cy)
    t = 0.75 - 0.6 * np.clip(np.hypot(x - cx, y - cy * 0.75) / 64, 0, 1)
    c.over(ramp(t, [(0, '#07050a'), (0.5, '#1d1420'), (1, '#4a3328')]), cov(rr - 64))
    c.save(name)


# ---------------------------------------------------------------- background

def make_bg(name='bg.png', W=720, Hh=1280):
    global S
    s_old = S
    S = 1
    w, h = W, Hh
    x, y = grid(w, h)
    n1 = fbm_tile(w, h, 2.3, 5, 1.5)
    n2 = fbm_tile(w, h, 1.5, 6, 6)
    n3 = fbm_tile(w, h, 0.8, 8, 40)
    t = 0.42 + 0.10 * n1 + 0.035 * n2 + 0.012 * n3
    col = ramp(t, [(0, '#050304'), (0.3, '#0f0a0a'), (0.5, '#1a1210'), (0.7, '#2a1d16'), (1, '#3e2b1f')])
    # leather relief lighting
    Hh_ = n1 * 1.5 + n2 * 0.35
    dif, _ = light(Hh_)
    col *= (0.82 + 0.3 * dif)[..., None]
    # faint embossed diamond lattice (tome cover tooling)
    u = (x - w / 2) / 90.0
    v = (y - 420) / 90.0
    a = np.abs(((u + v) % 1.0) - 0.5)
    b = np.abs(((u - v) % 1.0) - 0.5)
    lat = np.minimum(a, b) * 90 / 1.414
    groove = np.exp(-(lat / 1.1) ** 2)
    hi = np.exp(-((lat - 1.6) / 1.0) ** 2)
    fade = smooth(1.0, 0.25, np.hypot((x - w / 2) / (w * 0.75), (y - h * 0.45) / (h * 0.7)))
    col *= (1 - 0.30 * groove * fade)[..., None]
    col += (hexc('#5a3e28') * 0.10)[None, None, :] * (hi * fade)[..., None]
    # warm glow from top centre (torch light)
    gl = np.exp(-(((x - w / 2) / (w * 0.6)) ** 2 + ((y - h * 0.08) / (h * 0.35)) ** 2))
    col += hexc('#7a4416')[None, None, :] * (0.32 * gl)[..., None]
    # vignette
    vr = np.hypot((x - w / 2) / (w * 0.62), (y - h * 0.47) / (h * 0.62))
    vig = smooth(0.55, 1.35, vr)
    col *= (1 - 0.72 * vig)[..., None]
    c = Canvas(w, h)
    c.rgb = col
    c.a = np.ones((h, w))
    c.save(name)
    S = s_old


# ---------------------------------------------------------------- run
make_bg()
make_panel_dark()
make_panel_dark('panel_dark_plain.png', W=120, M=28, seed=12, guards=False)
make_panel_inset()
make_parchment()
for k in BTN:
    make_button(k)
    make_button(k, pressed=True)
make_slot('slot.png')
make_slot('slot_magic.png', glow='#3d8bff', seed=51)
make_slot('slot_rare.png', glow='#b04dff', seed=52)
make_slot('slot_legend.png', glow='#ff9a1f', seed=53)
make_tab('tab_on.png', True)
make_tab('tab_off.png', False)
make_bar_bg()
make_bar_fill('bar_fill_hp.png', [(0, '#2a0204'), (0.45, '#8a0c14'), (0.8, '#d42a2a'), (1, '#ff8a6a')])
make_bar_fill('bar_fill_xp.png', [(0, '#3a2204'), (0.45, '#a0680e'), (0.8, '#e6b03a'), (1, '#fff0a0')])
make_bar_fill('bar_fill_mana.png', [(0, '#03102a'), (0.45, '#12408e'), (0.8, '#2f7ad8'), (1, '#9ad0ff')])
make_divider()
make_ribbon()
make_portrait_frame()
make_portrait_bg()
