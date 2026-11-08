"""Compositions. Each returns (stereo float array, loop: bool)."""
import numpy as np
from synth import *

CH = {  # chord tones (midi-relative to C4=60 names)
}


def chord(root, kind="maj"):
    r = midi(root)
    iv = {"maj": [0, 4, 7], "min": [0, 3, 7], "maj7": [0, 4, 7, 11], "min7": [0, 3, 7, 10], "7": [0, 4, 7, 10],
          "sus4": [0, 5, 7], "sus2": [0, 2, 7], "dim": [0, 3, 6], "mmaj7": [0, 3, 7, 11], "min6": [0, 3, 7, 9],
          "add9": [0, 4, 7, 14], "m9": [0, 3, 7, 10, 14], "7b9": [0, 4, 7, 10, 13]}[kind]
    return [r + i for i in iv]


def mel(mix, t0, seq, unit, inst, octave=0, pan=0.0, gain=1.0, rev=0.3, jitter=0.006, legato=0.95, vel_var=0.1):
    t = t0
    rng = np.random.default_rng(int(t0 * 1000) % 99991)
    for name, d in parse(seq):
        if name:
            f = hz(midi(name) + 12 * octave)
            v = 1.0 - vel_var * rng.random()
            mix.add(t, inst(f, d * unit * legato, v), pan, gain, rev, jitter)
        t += d * unit
    return t


# ======================================================================= TOWN
def town():
    e = 0.2  # eighth, 6/8 at 100 bpm dotted-quarter
    bar = 6 * e
    prog_A = [("G3", "maj"), ("C3", "maj"), ("G3", "maj"), ("D3", "maj"), ("G3", "maj"), ("C3", "maj"),
              (("A2", "min"), ("D3", "maj")), ("G3", "maj")]
    prog_B = [("E3", "min"), ("C3", "maj"), ("G3", "maj"), ("D3", "maj"), ("E3", "min"), ("C3", "maj"),
              ("A2", "min"), ("D3", "maj")]
    melA = ("B4:2 A4:1 G4:2 B4:1 C5:2 E5:1 G5:2 E5:1 D5:2 B4:1 G4:2 B4:1 A4:2 B4:1 A4:2 F#4:1 "
            "G4:2 B4:1 D5:2 G5:1 E5:2 D5:1 C5:2 E5:1 C5:2 B4:1 A4:2 F#4:1 G4:5 r:1")
    melB = ("E5:2 G5:1 B5:2 G5:1 E5:2 G5:1 C6:2 G5:1 D5:2 G5:1 B5:2 G5:1 F#5:2 E5:1 D5:2 A4:1 "
            "B4:2 E5:1 G5:2 E5:1 C5:2 E5:1 G5:2 E5:1 A4:2 C5:1 E5:2 C5:1 D5:3 C5:2 A4:1")
    form = ["A", "A", "B", "A", "B", "A"]
    L = len(form) * 8 * bar
    m = Mix(L)
    t = 0.0
    for si, sec in enumerate(form):
        prog = prog_A if sec == "A" else prog_B
        for b, ch in enumerate(prog):
            tb = t + b * bar
            halves = [ch] if isinstance(ch[0], str) else list(ch)
            for hi, (root, kind) in enumerate(halves):
                span = 6 // len(halves)
                notes = chord(root, kind)
                r = notes[0]
                # lute arpeggio
                pat = [r, notes[1] + 12, notes[2] + 12, r + 24, notes[2] + 12, notes[1] + 12] if span == 6 else \
                    [r, notes[2] + 12, r + 24]
                for k, nn in enumerate(pat):
                    v = 0.9 if k == 0 else 0.6
                    m.add(tb + (hi * span + k) * e, pluck(hz(nn), e * 1.5, v, bright=0.45, ring=0.9), -0.25, 0.55, 0.25,
                          0.004)
                # bass
                m.add(tb + hi * span * e, bass(hz(r - 12), e * 2.6, 0.9), 0.0, 0.38, 0.1)
                if span == 6:
                    m.add(tb + 3 * e, bass(hz(notes[2] - 12), e * 2.6, 0.75), 0.0, 0.34, 0.1)
            # percussion after first section
            if si >= 1:
                m.add(tb, frame_drum(1.0, 180, 110), 0.1, 0.4, 0.15)
                m.add(tb + 3 * e, frame_drum(0.7, 170, 100, 0.2), 0.1, 0.5, 0.15)
                m.add(tb + 5 * e, frame_drum(0.35, 200, 120, 0.12), 0.1, 0.5, 0.15)
                for k in (2, 5):
                    m.add(tb + k * e, tamb(0.6), 0.45, 0.6, 0.2, 0.003)
        # melodies
        if sec == "A" and si > 0:
            mel(m, t, melA, e, flute, pan=0.2, gain=0.5, rev=0.3)
            if si == 5:
                mel(m, t, melA, e, fiddle, octave=-1, pan=-0.3, gain=0.22, rev=0.3)
        if sec == "B":
            mel(m, t, melB, e, fiddle, pan=0.15, gain=0.42, rev=0.3)
            if si == 4:
                mel(m, t, melB, e, flute, octave=-1, pan=-0.2, gain=0.25, rev=0.3)
        t += 8 * bar
    return m.render(rev_time=1.4, rev_lp=4500), True


# ======================================================================= WILD
def wild():
    q = 60 / 84
    bar = 4 * q
    prog = [("D3", "add9"), ("G2", "maj7"), ("B2", "min7"), ("A2", "sus4"), ("D3", "maj7"), ("E3", "min7"),
            ("G2", "maj7"), ("A2", "sus4")]
    p1 = "A5:3 F#5:1 G5:2 E5:1 D5:1 F#5:3 D5:1 E5:4 A4:1 D5:1 F#5:1 A5:1 B5:3 G5:1 A5:2 F#5:1 D5:1 E5:4"
    p2 = "D5:1 E5:1 F#5:2 G5:1 A5:1 B5:2 A5:2 F#5:1 D5:1 E5:4 F#5:2 A5:2 G5:1 F#5:1 E5:2 D5:2 C#5:1 A4:1 D5:4"
    phrases = 3
    L = phrases * 8 * bar
    m = Mix(L)
    rng = np.random.default_rng(3)
    for ph in range(phrases):
        for b, (root, kind) in enumerate(prog):
            tb = (ph * 8 + b) * bar
            notes = chord(root, kind)
            # pad
            for nn in notes:
                m.add(tb, strings(hz(nn + 12), bar, 0.5, att=1.0, rel=1.2, bright=1600), rng.uniform(-.5, .5), 0.22, 0.6)
            m.add(tb, bass(hz(notes[0] - 12), bar * 0.95, 0.7, decay=3), 0, 0.4, 0.2)
            # harp arpeggio (8ths), up then down
            arp = [notes[0] + 12, notes[1] + 12, notes[2] + 12, notes[-1] + 12 if len(notes) > 3 else notes[0] + 24,
                   notes[0] + 24, notes[1] + 24, notes[2] + 24, notes[1] + 24]
            for k, nn in enumerate(arp):
                v = 0.8 if k == 0 else 0.55
                m.add(tb + k * q / 2, pluck(hz(nn), q, v, bright=0.7, ring=2.0, body=False), 0.3 * np.sin(k), 0.38,
                      0.5, 0.005)
            # shaker on phrases 2,3
            if ph > 0:
                for k in range(8):
                    m.add(tb + k * q / 2, shaker(0.9 if k % 2 == 0 else 0.5), 0.5, 0.25, 0.3, 0.004)
                m.add(tb, frame_drum(0.5, 120, 70, 0.35), 0, 0.35, 0.4)
                m.add(tb + 2.5 * q, frame_drum(0.3, 120, 70, 0.3), 0, 0.35, 0.4)
        t0 = ph * 8 * bar
        if ph == 1:
            mel(m, t0, p1, q, flute, pan=0.1, gain=0.5, rev=0.5)
        if ph == 2:
            mel(m, t0, p2, q, flute, pan=0.1, gain=0.5, rev=0.5)
            mel(m, t0, p1, q, strings, octave=-1, pan=-0.3, gain=0.18, rev=0.5)
    # wind / air bed
    n = m.N
    air = np.stack([bp(noise(n), 300, 2500), bp(noise(n), 300, 2500)]) * (0.6 + 0.4 * lfo(n, 9))
    air = air / np.std(air) * 0.012
    out = m.render(rev_time=2.8, rev_lp=6000)
    return out + air, True


# ======================================================================= DUNGEON
def dungeon():
    beat = 1.0
    bar = 4 * beat
    prog = [("D3", "min"), ("D3", "min"), ("Bb2", "maj"), ("Bb2", "maj"), ("G2", "min"), ("G2", "min"), ("A2", "7b9"),
            ("A2", "maj")]
    bells1 = "D5:1 F5:1 E5:2 A4:4 r:4 D5:1 F5:1 G5:2 F5:1 E5:1 D5:2 r:4 Bb4:1 D5:1 C#5:2 A4:4"
    bells2 = "A5:2 G5:1 F5:1 E5:4 r:4 F5:2 E5:1 D5:1 C#5:4 r:4 D5:1 E5:1 F5:2 E5:4"
    cello = "D3:4 C3:4 Bb2:4 A2:4 G2:4 Bb2:4 A2:8"
    cycles = 2
    L = cycles * 8 * bar
    m = Mix(L)
    rng = np.random.default_rng(11)
    for c in range(cycles):
        for b, (root, kind) in enumerate(prog):
            tb = (c * 8 + b) * bar
            notes = chord(root, kind)
            # low drone on D always
            if b % 2 == 0:
                m.add(tb, drone(hz("D2"), 2 * bar, 0.9, cutoff=420, att=2.5, rel=2.5), 0, 0.28, 0.5)
                m.add(tb, drone(hz("A2"), 2 * bar, 0.5, cutoff=420, att=3.0, rel=2.5), 0.2, 0.22, 0.5)
                # chord pad low strings
                for nn in notes[1:]:
                    m.add(tb, strings(hz(nn + 12), 2 * bar, 0.5, att=2.0, rel=2.0, bright=1100), rng.uniform(-.6, .6),
                          0.18, 0.6)
                if c == 1:
                    for nn in notes[:3]:
                        m.add(tb, choir(hz(nn + 12), 2 * bar, 0.5, "o", att=2.0, rel=2.0), rng.uniform(-.6, .6), 0.16,
                              0.7)
            # distant drum
            m.add(tb, taiko(0.8, 110, 55, 0.8), 0, 0.3, 0.75)
            if b % 2 == 1:
                m.add(tb + 2.5 * beat, taiko(0.4, 110, 55, 0.6), 0, 0.28, 0.8)
        t0 = c * 8 * bar
        mel(m, t0, bells1 if c == 0 else bells2, beat, bell, pan=0.35, gain=0.32, rev=0.7, legato=1.0)
        if c == 1:
            mel(m, t0, cello, beat, strings, pan=-0.2, gain=0.35, rev=0.4)
    # drips
    for k in range(10):
        t = rng.uniform(0, L)
        m.add(t, drip(rng.uniform(900, 1800), 0.8), rng.uniform(-0.8, 0.8), 0.25, 0.8)
    n = m.N
    wind = np.stack([lp(noise(n), 500), lp(noise(n), 500)]) * (0.5 + 0.5 * lfo(n, 12)) ** 2
    wind = wind / np.std(wind) * 0.02
    out = m.render(rev_time=4.5, rev_lp=3500, predelay=0.04)
    return out + wind, True


# ======================================================================= COMBAT
def combat():
    q = 60 / 140
    e = q / 2
    bar = 4 * q
    prog = [("D3", "min"), ("D3", "min"), ("Bb2", "maj"), ("C3", "maj"), ("D3", "min"), ("D3", "min"), ("Bb2", "maj"),
            ("A2", "maj"), ("G2", "min"), ("G2", "min"), ("D3", "min"), ("D3", "min"), ("Bb2", "maj"), ("C3", "maj"),
            ("A2", "maj"), ("A2", "maj")]
    ost = [0, 0, 12, 0, 0, 10, 12, 7]
    melo = ("A4:2 D5:2 F5:3 E5:1 D5:2 F5:2 G5:2 E5:2 F5:2 E5:1 D5:1 A5:4 G5:2 F5:2 E5:4 "
            "G5:2 Bb5:2 A5:2 G5:2 F5:3 E5:1 D5:4 D5:1 E5:1 F5:2 G5:1 F5:1 E5:2 C#5:2 E5:2 A5:4")
    horn = "D4:4 D4:4 F4:4 E4:4 D4:4 F4:4 D4:4 C#4:4 Bb3:4 D4:4 A3:4 D4:4 D4:4 E4:4 E4:4 C#4:4"
    reps = 2
    L = reps * 16 * bar
    m = Mix(L)
    for r in range(reps):
        for b, (root, kind) in enumerate(prog):
            tb = (r * 16 + b) * bar
            notes = chord(root, kind)
            rt = notes[0]
            for k in range(8):
                nn = rt + ost[k]
                acc = 1.0 if k in (0, 3, 6) else 0.7
                m.add(tb + k * e, staccato_str(hz(nn), e * 0.7, acc), -0.3, 0.32, 0.15, 0.003)
                m.add(tb + k * e, staccato_str(hz(nn + 12), e * 0.6, acc * 0.8), 0.3, 0.3, 0.15, 0.003)
            m.add(tb, bass(hz(rt - 12), bar * 0.9, 0.9, decay=0.6), 0, 0.25, 0.05)
            # brass stab on 1 and "and of 2"
            for pos, v in ((0, 1.0), (1.5, 0.75)) if b % 4 in (0, 2) else ((0, 0.9),):
                for nn in notes:
                    m.add(tb + pos * q, brass(hz(nn + 12), q * 0.6, v * 0.7), 0.1, 0.28, 0.3)
            # drums
            for pos in (0, 1.5, 2, 3.5):
                m.add(tb + pos * q, taiko(1.0 if pos in (0, 2) else 0.7, 130, 62), 0, 0.24, 0.25)
            for pos in (1, 3):
                m.add(tb + pos * q, snare(0.8), 0.15, 0.45, 0.25)
            for k in range(8):
                m.add(tb + k * e, shaker(0.8 if k % 2 else 0.5), 0.5, 0.3, 0.15, 0.003)
            if b == 15:
                for k, pos in enumerate((2, 2.5, 3, 3.25, 3.5, 3.75)):
                    m.add(tb + pos * q, taiko(0.6 + 0.07 * k, 160, 90, 0.3), -0.3 + 0.12 * k, 0.35, 0.3)
            if b % 8 == 0:
                m.add(tb, cymbal(0.8, 0, 1.2), 0.3, 0.5, 0.4)
        t0 = r * 16 * bar
        if r == 0:
            mel(m, t0, horn, q, brass, pan=-0.15, gain=0.35, rev=0.35)
        else:
            mel(m, t0, melo, q, strings, pan=0.1, gain=0.5, rev=0.35, legato=0.98)
            mel(m, t0, melo, q, brass, octave=-1, pan=-0.2, gain=0.22, rev=0.35)
    return m.render(rev_time=1.8, rev_lp=5000), True


# ======================================================================= SEA
def sea():
    e = 60 / 92 / 3
    bar = 6 * e
    prog_A = [("A2", "min"), ("A2", "min"), ("G2", "maj"), ("G2", "maj"), ("A2", "min"), ("A2", "min"), ("E2", "min"),
              ("A2", "min")]
    prog_B = [("C3", "maj"), ("G2", "maj"), ("A2", "min"), ("E2", "min"), ("F2", "maj"), ("G2", "maj"), ("E2", "maj"),
              ("A2", "min")]
    melA = ("E5:2 E5:1 E5:2 D5:1 C5:2 D5:1 E5:2 A4:1 D5:2 B4:1 G4:2 B4:1 D5:2 E5:1 D5:2 B4:1 "
            "E5:2 E5:1 A5:2 G5:1 E5:2 D5:1 C5:2 A4:1 B4:2 C5:1 D5:2 B4:1 A4:5 r:1")
    melB = ("G5:2 E5:1 C5:2 E5:1 D5:2 B4:1 G4:2 B4:1 C5:2 D5:1 E5:2 A5:1 G5:2 F#5:1 E5:2 B4:1 "
            "A5:2 F5:1 C5:2 F5:1 G5:2 D5:1 B4:2 D5:1 E5:2 D5:1 B4:2 G#4:1 A4:5 r:1")
    form = ["A", "A", "B", "A", "B"]
    L = len(form) * 8 * bar
    m = Mix(L)
    t = 0.0
    for si, sec in enumerate(form):
        prog = prog_A if sec == "A" else prog_B
        for b, (root, kind) in enumerate(prog):
            tb = t + b * bar
            notes = chord(root, kind)
            m.add(tb, bass(hz(notes[0] - 12), e * 2.5, 1.0, 0.4), 0, 0.33, 0.1)
            m.add(tb + 3 * e, bass(hz(notes[2] - 12), e * 2.5, 0.8, 0.4), 0, 0.28, 0.1)
            for pos in (1, 2, 4, 5):
                v = 0.75 if pos in (1, 4) else 0.5
                for nn in notes:
                    m.add(tb + pos * e, reed(hz(nn + 12), e * 0.75, v), -0.25, 0.3, 0.2, 0.003)
            m.add(tb, frame_drum(1.0, 160, 95, 0.3), 0, 0.38, 0.2)
            m.add(tb + 3 * e, frame_drum(0.8, 160, 95, 0.28), 0, 0.34, 0.2)
            if si >= 1:
                for pos in (2, 5):
                    m.add(tb + pos * e, tamb(0.5), 0.4, 0.5, 0.2)
                # stomp-ish clap
                m.add(tb + 3 * e, snare(0.35), 0.2, 0.3, 0.3)
        if sec == "A" and si > 0:
            mel(m, t, melA, e, fiddle, pan=0.2, gain=0.45, rev=0.3)
            if si == 3:
                mel(m, t, melA, e, reed, octave=-1, pan=-0.3, gain=0.35, rev=0.3)
        if sec == "B":
            mel(m, t, melB, e, fiddle, pan=0.2, gain=0.45, rev=0.3)
            mel(m, t, melB, e, flute, octave=0, pan=-0.2, gain=0.22, rev=0.3)
        t += 8 * bar
    n = m.N
    waves = np.stack([lp(noise(n), 900), lp(noise(n), 900)])
    w = np.clip(lfo(n, 6.5), 0, None) ** 2 * 0.8 + 0.2
    waves = waves * w / np.std(waves) * 0.02
    return m.render(rev_time=1.6, rev_lp=4500) + waves, True


# ======================================================================= MYSTERY
def mystery():
    q = 60 / 76
    bar = 3 * q
    prog = [["A2", "C4", "E4", "A4"], ["G#2", "C4", "E4", "B4"], ["G2", "C4", "E4", "A4"], ["F#2", "A3", "D4", "F#4"],
            ["F2", "A3", "C4", "E4"], ["D2", "F3", "A3", "B3"], ["E2", "G#3", "D4", "B4"], ["E2", "G#3", "D4", "E4"]]
    box1 = "E5:1 A5:1 C6:1 B5:2 G#5:1 A5:1 E5:1 C5:1 A5:2 F#5:1 E5:1 F5:1 A5:1 B5:2 F5:1 G#5:1 B5:1 D6:1 E5:3"
    box2 = "C6:1 B5:1 A5:1 G#5:2 E5:1 G5:1 E5:1 C5:1 F#5:2 D5:1 E5:1 C5:1 A4:1 B4:2 D5:1 E5:1 G#5:1 B5:1 E6:3"
    ther = "A5:3 G#5:3 G5:3 F#5:3 F5:3 F5:2 E5:1 G#5:3 E5:3"
    phrases = 3
    L = phrases * 8 * bar
    m = Mix(L)
    rng = np.random.default_rng(5)
    for ph in range(phrases):
        for b, ch in enumerate(prog):
            tb = (ph * 8 + b) * bar
            ms = [midi(x) for x in ch]
            m.add(tb, bass(hz(ms[0]), bar, 0.7, decay=2.0), 0, 0.28, 0.4)
            for nn in ms[1:]:
                m.add(tb, strings(hz(nn), bar, 0.45, att=0.9, rel=1.4, bright=1300), rng.uniform(-.7, .7), 0.2, 0.7)
            # celesta waltz arpeggio: beat 2 & 3
            for k, pos in enumerate((1, 1.5, 2, 2.5)):
                nn = ms[1 + (k % 3)] + 12
                m.add(tb + pos * q, celesta(hz(nn), q, 0.45), 0.4, 0.3, 0.6, 0.006)
            if ph == 2:
                for nn in ms[1:]:
                    m.add(tb, choir(hz(nn), bar, 0.35, "u", att=1.0, rel=1.5), rng.uniform(-.7, .7), 0.14, 0.8)
            # heartbeat-ish low drum on 1
            if ph >= 1:
                m.add(tb, taiko(0.45, 90, 50, 0.5), 0, 0.25, 0.6)
                m.add(tb + 0.35, taiko(0.3, 90, 50, 0.4), 0, 0.2, 0.6)
        t0 = ph * 8 * bar
        if ph == 1:
            mel(m, t0, box1, q, musicbox, pan=-0.1, gain=0.45, rev=0.65, legato=1.0)
        if ph == 2:
            mel(m, t0, box2, q, musicbox, pan=-0.1, gain=0.4, rev=0.65, legato=1.0)

            def theremin(f, d, v):
                n = int((d + 0.5) * SR)
                fr = vibrato(n, f, 6.0, 0.012, 0.15)
                x = wt(fr, [1, .08, .03], n)
                return v * x * env_adsr(n, 0.3, 0.2, 0.9, 0.5, hold=int(d * SR))

            mel(m, t0, ther, q, theremin, pan=0.3, gain=0.2, rev=0.7)
    n = m.N
    wind = np.stack([bp(noise(n), 400, 1800), bp(noise(n), 400, 1800)]) * (0.4 + 0.6 * np.abs(lfo(n, 14)))
    wind = wind / np.std(wind) * 0.015
    return m.render(rev_time=3.5, rev_lp=4000, predelay=0.03) + wind, True


# ======================================================================= MENU
def menu():
    q = 60 / 72
    bar = 4 * q
    prog = [("D3", "min"), ("Bb2", "maj"), ("F3", "maj"), ("C3", "maj"), ("D3", "min"), ("Bb2", "maj"), ("G2", "min"),
            ("A2", "maj"),
            ("Bb2", "maj"), ("F3", "maj"), ("G2", "min"), ("D3", "min"), ("Bb2", "maj"), ("C3", "maj"), ("A2", "sus4"),
            ("A2", "maj"),
            ("D3", "min"), ("Bb2", "maj"), ("F3", "maj"), ("A2", "maj")]
    vio = "A4:4 Bb4:2 D5:2 C5:4 E5:2 G4:2 F4:2 A4:2 D5:4 Bb4:2 D5:2 C#5:4"
    horn = "D5:3 C5:1 C5:2 A4:2 Bb4:2 D5:2 A4:4 F5:3 E5:1 E5:2 G5:2 D5:3 E5:1 C#5:4"
    outro = "D5:2 F5:2 F5:3 D5:1 C5:2 A4:2 A4:4"
    L = len(prog) * bar
    m = Mix(L)
    rng = np.random.default_rng(9)
    for b, (root, kind) in enumerate(prog):
        tb = b * bar
        notes = chord(root, kind)
        for nn in notes:
            m.add(tb, strings(hz(nn + 12), bar, 0.55, att=0.8, rel=1.3, bright=1800), rng.uniform(-.6, .6), 0.22, 0.6)
        m.add(tb, strings(hz(notes[0] - 12), bar, 0.7, att=0.5, rel=1.0, bright=900), -0.1, 0.35, 0.4)
        arp = [notes[0] + 12, notes[1] + 12, notes[2] + 12, notes[0] + 24, notes[1] + 24, notes[0] + 24, notes[2] + 12,
               notes[1] + 12]
        for k, nn in enumerate(arp):
            m.add(tb + k * q / 2, pluck(hz(nn), q, 0.7 if k == 0 else 0.5, bright=0.65, ring=2.0, body=False),
                  0.35, 0.3, 0.55, 0.005)
        if b >= 8:
            for nn in notes:
                m.add(tb, choir(hz(nn + 12), bar, 0.5, "a", att=1.0, rel=1.4), rng.uniform(-.7, .7), 0.15, 0.7)
        if b in (0, 8, 16):
            m.add(tb - 1.6, timpani(hz("D2"), 0.6, roll=1.6), 0, 0.5, 0.4)
            m.add(tb, cymbal(0.5, 0, 2.5), 0.2, 0.4, 0.6)
        if b % 2 == 0:
            m.add(tb, timpani(hz(notes[0] - 12) if notes[0] - 12 >= midi("F2") else hz(notes[0]), 0.5), 0, 0.35, 0.5)
    mel(m, 0, vio, q, strings, pan=0.15, gain=0.38, rev=0.5)
    mel(m, 8 * bar, horn, q, brass, pan=-0.1, gain=0.42, rev=0.5)
    mel(m, 8 * bar, horn, q, strings, octave=1, pan=0.25, gain=0.18, rev=0.5)
    mel(m, 16 * bar, outro, q, strings, pan=0.15, gain=0.4, rev=0.5)
    mel(m, 16 * bar, outro, q, brass, octave=-1, pan=-0.15, gain=0.25, rev=0.5)
    return m.render(rev_time=3.2, rev_lp=5000, predelay=0.03), True


# ======================================================================= VICTORY
def victory():
    L = 4.2
    m = Mix(L, loop=False, tail=0.0)
    seq = [(0.0, "A4", .14), (0.15, "A4", .14), (0.30, "A4", .14), (0.45, "D5", .5), (0.95, "C5", .25),
           (1.2, "E5", .25), (1.45, "D5", 2.0)]
    for t, n, d in seq:
        m.add(t + 0.05, brass(hz(n), d, 0.95, 1.2), 0.0, 0.45, 0.3)
        m.add(t + 0.05, brass(hz(midi(n) - 12), d, 0.7), -0.2, 0.25, 0.3)
    for nn in ("D4", "F#4", "A4", "D5"):
        m.add(1.5, brass(hz(nn), 1.8, 0.7), np.random.uniform(-.4, .4), 0.18, 0.4)
        m.add(1.5, strings(hz(nn), 1.8, 0.6, att=0.1, rel=1.0, bright=3000), 0.3, 0.2, 0.4)
    m.add(0.0, timpani(hz("A2"), 0.5, roll=0.4), 0, 0.5, 0.3)
    m.add(1.5, timpani(hz("D2"), 1.0), 0, 0.7, 0.3)
    m.add(1.5, cymbal(0.9, 0, 1.5), 0.2, 0.6, 0.4)
    for k, nn in enumerate(("D6", "F#6", "A6", "D7")):
        m.add(1.5 + 0.06 * k, celesta(hz(nn), 0.5, 0.5), 0.4, 0.3, 0.5)
    x = m.render(rev_time=2.0, rev_lp=6000)
    n = x.shape[1]
    t = np.arange(n) / SR
    fade = np.clip((L - t) / 1.0, 0, 1) ** 2
    return x * fade, False


SONGS = {"town": town, "wild": wild, "dungeon": dungeon, "combat": combat, "sea": sea, "mystery": mystery,
         "menu": menu, "victory": victory}
