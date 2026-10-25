#!/usr/bin/env python3
"""Synthesise "Bergamota Mi", an original Xiaomi/Redmi-style ringtone:
clean, bright and modern, with notes written from scratch (no existing melody).
Instruments (all synthesised, pure numpy, stereo 44.1 kHz):
  - FM electric piano (Rhodes-like) lead
  - FM glass bell sparkles
  - additive nylon-style pluck arpeggios
  - detuned supersaw pad with sidechain pump
  - warm sub bass
  - kick, clap, hi-hat, shaker
plus a convolution reverb."""
import sys, wave
import numpy as np

SR = 44100
BPM = 110
B = 60.0 / BPM               # one beat in seconds
rng = np.random.default_rng(2026)


def hz(note):
    names = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
    n = names[note[0]]; i = 1
    if note[i] == '#': n += 1; i += 1
    elif note[i] == 'b': n -= 1; i += 1
    return 440.0 * 2 ** ((n + 12 * (int(note[i:]) + 1) - 69) / 12)


def tx(dur):
    return np.arange(int(dur * SR)) / SR


def adsr(t, a, dur, r):
    return np.clip(np.minimum(t / a, (dur - t) / r), 0, 1)


# ---------------------------------------------------------------- instruments
def epiano(f, dur):
    """FM Rhodes: 1:1 body with decaying index + 14:1 tine click."""
    t = tx(dur + 0.8)
    idx = 1.6 * np.exp(-t * 4) + 0.25
    body = np.sin(2*np.pi*f*t + idx*np.sin(2*np.pi*f*t))
    tine = np.sin(2*np.pi*f*t + 0.9*np.exp(-t*40)*np.sin(2*np.pi*14*f*t))
    env = np.exp(-t * 1.6) * np.clip(np.minimum(t/0.003, (dur + 0.8 - t)/0.25), 0, 1)
    return (0.8*body + 0.25*tine*np.exp(-t*12)) * env * 0.32


def bell(f, dur=1.6):
    t = tx(dur)
    m = 2.5 * np.exp(-t * 3) * np.sin(2*np.pi*3.5*f*t)
    s = np.sin(2*np.pi*f*t + m) + 0.3*np.sin(2*np.pi*2.756*f*t)*np.exp(-t*5)
    return s * np.exp(-t * 3.2) * np.minimum(1, t/0.002) * 0.12


def pluck(f, dur=1.2, bright=1.0):
    """Additive nylon pluck: higher partials die faster, slight inharmonicity."""
    t = tx(dur); s = np.zeros_like(t)
    for k in range(1, 16):
        fk = k * f * (1 + 0.0004 * k * k)
        if fk > 12000: break
        amp = (1.0 / k) * np.sin(np.pi * k * 0.23) ** 2 * bright ** (k - 1)
        s += amp * np.sin(2*np.pi*fk*t) * np.exp(-t * (2.2 + 1.1*k))
    return s * np.minimum(1, t/0.0015) * 0.35


def supersaw(freqs, dur):
    t = tx(dur); s = np.zeros_like(t)
    for f in freqs:
        for d in (-0.012, -0.005, 0, 0.005, 0.012):
            fd = f * (1 + d); ph = rng.uniform(0, 2*np.pi)
            for k in range(1, 30):
                if k * fd > 3500: break
                s += np.sin(2*np.pi*k*fd*t + k*ph) / k * np.exp(-k * 0.12)
    return s * adsr(t, 0.25, dur, 0.4) * 0.012


def bass(f, dur):
    t = tx(dur)
    # extra upper harmonics so the bass line is still heard on small phone speakers
    s = np.sin(2*np.pi*f*t) + 0.5*np.sin(2*np.pi*2*f*t) + 0.3*np.sin(2*np.pi*3*f*t) + 0.15*np.sin(2*np.pi*4*f*t)
    return np.tanh(1.6 * s) * adsr(t, 0.01, dur, 0.06) * 0.16


def kick():
    t = tx(0.4)
    ph = 2*np.pi*np.cumsum(45 + 120*np.exp(-t*35)) / SR
    click = rng.standard_normal(len(t)) * np.exp(-t*400) * 0.2
    return (np.sin(ph) * np.exp(-t*9) + click) * 0.32


def clap():
    t = tx(0.3); n = rng.standard_normal(len(t))
    n = np.diff(n, prepend=0)          # brighten
    env = np.exp(-t*25) + sum(np.exp(-np.maximum(t-d, 0)*200)*(t >= d) for d in (0, 0.011, 0.022))*0.4
    return n * env * 0.10


def hat(open_=False):
    t = tx(0.25 if open_ else 0.06); n = rng.standard_normal(len(t))
    n = np.diff(np.diff(n, prepend=0), prepend=0)
    return n * np.exp(-t * (14 if open_ else 70)) * 0.035


def shaker():
    t = tx(0.09); n = np.diff(rng.standard_normal(len(t)), prepend=0)
    return n * np.sin(np.pi * t / 0.09) ** 2 * 0.03


# --------------------------------------------------------------------- mixer
class Mix:
    def __init__(self, seconds):
        self.L = np.zeros(int(seconds * SR)); self.R = np.zeros_like(self.L)

    def add(self, sig, beat, pan=0.0, gain=1.0):
        i = int(beat * B * SR)
        n = min(len(sig), len(self.L) - i)
        if n <= 0: return
        l = np.cos((pan + 1) * np.pi / 4) * gain; r = np.sin((pan + 1) * np.pi / 4) * gain
        self.L[i:i+n] += sig[:n] * l * 1.41; self.R[i:i+n] += sig[:n] * r * 1.41


def reverb(x, seed, secs=1.9):
    t = tx(secs); g = np.random.default_rng(seed)
    ir = g.standard_normal(len(t)) * np.exp(-t * 3.4)
    ir = np.convolve(ir, np.ones(6) / 6, 'same')           # darken tail
    ir[:int(0.02*SR)] = 0                                   # pre-delay
    n = 1 << int(np.ceil(np.log2(len(x) + len(ir))))
    y = np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(ir, n), n)[:len(x)]
    return y / np.sqrt((ir ** 2).sum())


# --------------------------------------------------------------------- score
# Chords per bar (4 beats). Original progression with a borrowed bVII lift.
CHORDS = [  # (pad notes, bass root, arpeggio notes)
    (['D3', 'F#3', 'A3', 'E4'],  'D2',  ['D4', 'A4', 'E5', 'F#5']),   # Dadd9
    (['C#3', 'E3', 'A3', 'B3'],  'C#2', ['A3', 'E4', 'B4', 'C#5']),   # A/C#
    (['B2', 'D3', 'F#3', 'A3'],  'B1',  ['B3', 'F#4', 'A4', 'D5']),   # Bm7
    (['G2', 'B2', 'D3', 'F#3'],  'G1',  ['G3', 'D4', 'F#4', 'B4']),   # Gmaj7
    (['E3', 'G3', 'B3', 'D4'],   'E2',  ['E4', 'B4', 'D5', 'G5']),    # Em7
    (['C3', 'E3', 'G3', 'D4'],   'C2',  ['C4', 'G4', 'D5', 'E5']),    # Cadd9 (bVII)
    (['A2', 'D3', 'E3', 'G3'],   'A1',  ['A3', 'E4', 'G4', 'D5']),    # A7sus4
    (['A2', 'C#3', 'E3', 'G3'],  'A1',  ['A3', 'E4', 'G4', 'C#5']),   # A7
]
# Lead melody per bar: (note or None, beats)
LEAD = [
    [('A5', 0.75), ('F#5', 0.75), ('E5', 0.5), ('A5', 1), ('B5', 1)],
    [('C#6', 0.5), ('E6', 1), ('B5', 0.5), ('A5', 0.5), ('E5', 1.5)],
    [('F#5', 0.75), ('A5', 0.75), ('D6', 0.5), ('C#6', 0.5), ('A5', 0.5), ('F#5', 1)],
    [('G5', 0.5), ('A5', 0.5), ('B5', 1.5), (None, 0.5), ('F#5', 0.5), ('A5', 0.5)],
    [('G5', 0.75), ('B5', 0.75), ('E6', 1.0), ('D6', 0.5), ('B5', 1)],
    [('C6', 0.5), ('D6', 0.5), ('E6', 1.0), ('G6', 1.0), ('E6', 1)],
    [('D6', 0.75), ('E6', 0.75), ('A5', 0.5), ('D6', 2)],
    [('C#6', 0.75), ('B5', 0.75), ('A5', 0.5), ('E6', 1), ('G6', 1)],
]


def main(out_wav):
    INTRO, BARS = 2, 8
    total_beats = (INTRO + BARS + 2) * 4
    m = Mix(total_beats * B + 2.5)
    pump_env = np.ones(len(m.L))

    # intro: pluck arpeggio + bell sparkle over the first two chords
    for bar in range(INTRO):
        _, _, arp = CHORDS[bar]
        for k in range(8):
            n = arp[[0, 1, 2, 3, 2, 1, 3, 2][k]]
            m.add(pluck(hz(n), 1.0, 0.9), bar*4 + k*0.5, pan=(-0.4 if k % 2 else 0.4), gain=1.4)
        m.add(bell(hz(arp[3]) * 2), bar*4, pan=0.2, gain=1.5)
    m.add(supersaw([hz(n) for n in CHORDS[0][0]], 2 * 4 * B), 0, gain=0.5)
    m.add(hat(True), INTRO*4 - 0.5, pan=0.3)

    # main: 8 bars full band
    for bar in range(BARS):
        b0 = (INTRO + bar) * 4
        padn, root, arp = CHORDS[bar]
        full = bar >= 2
        m.add(supersaw([hz(n) for n in padn], 4 * B + 0.3), b0, gain=0.9)
        # bass: syncopated, pumping
        for beat, length in ((0, 0.75), (1, 0.5), (1.5, 0.75), (2.5, 0.5), (3, 0.5), (3.5, 0.5)):
            m.add(bass(hz(root), length * B * 0.9), b0 + beat, gain=0.9 if full else 0.6)
        # pluck arpeggio 16ths-ish pattern
        pat = [0, 2, 1, 3, 2, 1, 3, 2]
        for k in range(8):
            m.add(pluck(hz(arp[pat[k]]), 0.9, 0.85), b0 + k*0.5, pan=-0.45 if k % 2 else 0.45, gain=0.55)
        # drums
        for beat in range(4):
            m.add(kick(), b0 + beat)
            s = int((b0 + beat) * B * SR)
            pump_env[s:s+int(0.35*SR)] = np.minimum(pump_env[s:s+int(0.35*SR)],
                                                    0.45 + 0.55*np.linspace(0, 1, int(0.35*SR))**0.6)
            if full and beat in (1, 3):
                m.add(clap(), b0 + beat, pan=0.05)
            m.add(hat(), b0 + beat + 0.5, pan=0.35)
            if full:
                m.add(shaker(), b0 + beat + 0.25, pan=-0.5)
                m.add(shaker(), b0 + beat + 0.75, pan=-0.5)
        if bar in (3, 7):
            m.add(hat(True), b0 + 3.5, pan=0.3)
        # lead
        pos = b0
        for n, l in LEAD[bar]:
            if n:
                m.add(epiano(hz(n), l * B), pos, pan=0.0)
                if full and l >= 1:
                    m.add(bell(hz(n) * 2, 1.2), pos, pan=-0.25, gain=0.7)
            pos += l

    # outro: big D chord ring
    b0 = (INTRO + BARS) * 4
    m.add(kick(), b0)
    for n, p in (('D4', -0.4), ('A4', 0.4), ('E5', -0.2), ('F#5', 0.2), ('A5', 0)):
        m.add(pluck(hz(n), 2.5, 0.9), b0, pan=p, gain=0.8)
    m.add(epiano(hz('D6'), 3 * B), b0)
    m.add(bell(hz('A6'), 2.5), b0 + 0.5, pan=0.3)
    m.add(bell(hz('D7'), 2.5), b0 + 1.0, pan=-0.3, gain=0.7)
    m.add(supersaw([hz(n) for n in ('D3', 'A3', 'E4', 'F#4')], 4 * B + 1), b0, gain=0.8)
    m.add(bass(hz('D2'), 3 * B), b0)

    end = int((b0 + 4) * B * SR + 1.2 * SR)
    L, R = m.L[:end], m.R[:end]
    pump = pump_env[:end]
    L = L * (0.55 + 0.45*pump); R = R * (0.55 + 0.45*pump)  # gentle sidechain glue
    wetL, wetR = reverb(L, 1), reverb(R, 2)
    L = L + 0.22 * wetL; R = R + 0.22 * wetR
    peak = max(np.abs(L).max(), np.abs(R).max())
    L, R = L / peak, R / peak
    L, R = np.tanh(L * 1.5) / np.tanh(1.5), np.tanh(R * 1.5) / np.tanh(1.5)
    L, R = L * 0.92, R * 0.92
    f = int(0.8 * SR); fade = np.linspace(1, 0, f) ** 2
    L[-f:] *= fade; R[-f:] *= fade
    pcm = (np.stack([L, R], 1) * 32767).astype('<i2')
    with wave.open(out_wav, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{out_wav}: {end / SR:.1f}s")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'mi.wav')
