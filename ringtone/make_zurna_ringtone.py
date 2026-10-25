#!/usr/bin/env python3
"""Synthesise "Bergamota Mi Zurna": the Bergamota Mi melody played on a
synthesised zurna (lead + dem drone) over a davul, wedding style.
Zurna: phase-continuous additive double-reed tone with nasal formants,
glides, grace notes, trills, growing vibrato and breath noise.
Davul: tokmak (deep boom) and çubuk (thin stick) heads."""
import sys, wave
import numpy as np
from make_mi_ringtone import SR, hz, tx, reverb, LEAD

BPM = 118
B = 60.0 / BPM
rng = np.random.default_rng(1453)


def down(note, octaves=1):
    i = 2 if note[1] in '#b' else 1
    return note[:i] + str(int(note[i:]) - octaves)


# ------------------------------------------------------------------ zurna
def formant_gain(f):
    lf = np.log2(np.maximum(f, 1))
    g = 0.35 + 1.0*np.exp(-((lf - np.log2(1250))/0.45)**2) \
        + 0.7*np.exp(-((lf - np.log2(2900))/0.35)**2)
    return g * (f < 15000)


def zurna_line(events, total, glide=0.022, vib_rate=5.8, bend=None, gain=None):
    """events: list of (start_s, dur_s, freq_hz, accent). Monophonic legato line.
    bend: optional per-sample pitch offset in octaves; gain: optional per-sample gain."""
    n = int(total * SR)
    logf = np.full(n, np.nan); amp = np.zeros(n); vibw = np.zeros(n)
    for start, dur, f, acc in events:
        a, b = int(start*SR), min(n, int((start+dur)*SR))
        logf[a:b] = np.log2(f)
        t = np.arange(b - a) / SR
        env = np.minimum(1, t/0.012) * np.clip((dur - t)/0.01, 0, 1)
        env *= 1 - 0.3*acc*np.exp(-t*60)        # tongue articulation dip
        amp[a:b] = np.maximum(amp[a:b], env)
        vibw[a:b] = np.clip((t - 0.18)/0.4, 0, 1) * (dur > 0.35)   # vibrato grows on long notes
    # hold pitch through rests, then smooth -> glides between notes
    idx = np.where(~np.isnan(logf), np.arange(n), 0)
    np.maximum.accumulate(idx, out=idx)
    logf = logf[idx]; logf[np.isnan(logf)] = np.log2(440)
    k = int(glide*SR); win = np.ones(k)/k
    logf = np.convolve(np.pad(logf, (k, k), 'edge'), win, 'same')[k:-k]
    t = np.arange(n)/SR
    vib = 0.018*vibw*np.sin(2*np.pi*vib_rate*t + 0.3*np.sin(2*np.pi*0.7*t))
    f = 2 ** (logf + vib/1.0 * 0.5 + (0 if bend is None else bend[:n]))
    ph = 2*np.pi*np.cumsum(f)/SR
    s = np.zeros(n)
    for h in range(1, 26):
        s += formant_gain(h*f) * h**-0.55 * np.sin(h*ph + 0.4*h)
    breath = np.diff(rng.standard_normal(n), prepend=0)
    breath = np.convolve(breath, np.ones(3)/3, 'same')
    sm = np.convolve(amp, np.ones(64)/64, 'same')
    if gain is not None:
        sm = sm * gain[:n]
    out = np.tanh(0.6 * s * sm) + 0.05*breath*sm
    return out * 0.5


def ev(beat, beats, note, acc=1):
    return (beat*B, beats*B, hz(note), acc)


def ornament(beat, beats, note, upper):
    """Grace note from above + trill at the end of long notes."""
    out = []
    g = 0.12
    if beats >= 0.75:
        out.append(ev(beat, g, upper)); out.append(ev(beat+g, beats-g, note, 0))
    else:
        out.append(ev(beat, beats, note))
    if beats >= 1.5:     # trill over the last half beat
        tail = beat + beats - 0.5
        out[-1] = (out[-1][0], (tail - (beat+g))*B, out[-1][2], 0)
        for i in range(6):
            out.append(ev(tail + i/12, 1/12, upper if i % 2 == 0 else note, 0))
    return out


def upper_of(note):
    """Upper neighbour in D major (C natural, from the Cadd9 bar, goes up to D)."""
    i = 2 if note[1] in '#b' else 1
    name, octv = note[:i], int(note[i:])
    nxt = {'D': 'E', 'E': 'F#', 'F#': 'G', 'G': 'A', 'A': 'B', 'B': 'C#', 'C#': 'D', 'C': 'D'}[name]
    return nxt + str(octv + (1 if name == 'B' else 0))


# ------------------------------------------------------------------ davul
def tokmak():
    t = tx(0.6)
    ph = 2*np.pi*np.cumsum(62 + 55*np.exp(-t*25))/SR
    body = np.sin(ph) + 0.4*np.sin(1.6*ph)*np.exp(-t*12)
    skin = np.convolve(rng.standard_normal(len(t)), np.ones(20)/20, 'same')*np.exp(-t*30)
    return (body*np.exp(-t*5.5) + 0.8*skin) * 0.55


def cubuk(v=1.0):
    t = tx(0.12)
    n = np.diff(rng.standard_normal(len(t)), prepend=0)*np.exp(-t*90)
    ring = np.sin(2*np.pi*420*t)*np.exp(-t*45) + 0.5*np.sin(2*np.pi*690*t)*np.exp(-t*60)
    return (0.25*n + 0.35*ring) * v * 0.45


def place(buf, sig, beat, g=1.0):
    i = int(beat*B*SR); n = min(len(sig), len(buf)-i)
    if n > 0: buf[i:i+n] += sig[:n]*g


def main(out_wav):
    INTRO = 2
    bars = INTRO + 8 + 1
    total = bars*4*B + 2.5
    n = int(total*SR)

    # ----- zurna lead
    events = []
    # intro bar 2: fanfare run up to D5 with long trilled hold
    run = ['D4', 'E4', 'F#4', 'G4', 'A4', 'B4', 'C#5']
    for i, nt in enumerate(run):
        events.append(ev(4 + i*0.25, 0.25, nt))
    events += ornament(4 + 1.75, 2.25, 'D5', 'E5')
    # main melody (Bergamota Mi lead, one octave down for the zurna's sweet spot)
    pos = INTRO*4
    for bar in LEAD:
        for nt, l in bar:
            if nt:
                z = down(nt)
                events += ornament(pos, l, z, upper_of(z))
            pos += l
    # ending: run down to a long D5 with trill and a final upward flick
    end = pos
    for i, nt in enumerate(['A5', 'G5', 'F#5', 'E5']):
        events.append(ev(end + i*0.25, 0.25, nt))
    events += ornament(end + 1, 2.25, 'D5', 'E5')
    events.append(ev(end + 3.3, 0.35, 'A5'))
    lead = zurna_line(events, total)

    # ----- second zurna holding the dem (drone) on D4 / A3
    dem_events = [ev(0.5, (bars*4 - 0.5), 'D4', 0)]
    dem = zurna_line(dem_events, total, vib_rate=4.9) * 0.28

    # ----- davul: düm-tek groove, rolls at phrase ends
    dav = np.zeros(n)
    for bar in range(bars):
        b0 = bar*4
        if bar == bars - 1:
            place(dav, tokmak(), b0, 1.2); place(dav, cubuk(), b0)
            continue
        for b in (0, 1.5, 2.5):
            place(dav, tokmak(), b0 + b)
        for b in (1, 2, 3, 3.5):
            place(dav, cubuk(), b0 + b)
        for b in np.arange(0, 4, 0.25):       # light ghost strokes
            place(dav, cubuk(0.3), b0 + b + 0.125)
        if bar in (1, 5, 9):                  # roll into the next phrase
            for k in range(8):
                place(dav, cubuk(0.5 + k*0.07), b0 + 3 + k/8)

    L = 0.95*lead + 0.75*dem + dav*0.9
    R = 0.95*lead + 1.05*dem + dav*0.9
    # zurna is a loud outdoor instrument: short, bright slap-back instead of a long hall
    L = L + 0.18*reverb(L, 5, 1.1); R = R + 0.18*reverb(R, 6, 1.1)
    stop = int((bars*4)*B*SR + 1.3*SR)
    L, R = L[:stop], R[:stop]
    pk = max(abs(L).max(), abs(R).max())
    L, R = np.tanh(1.4*L/pk)/np.tanh(1.4)*0.92, np.tanh(1.4*R/pk)/np.tanh(1.4)*0.92
    f = int(0.7*SR); fade = np.linspace(1, 0, f)**2
    L[-f:] *= fade; R[-f:] *= fade
    pcm = (np.stack([L, R], 1)*32767).astype('<i2')
    with wave.open(out_wav, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{out_wav}: {stop/SR:.1f}s")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'zurna.wav')
