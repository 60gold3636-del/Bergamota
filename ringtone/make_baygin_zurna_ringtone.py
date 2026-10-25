#!/usr/bin/env python3
"""Synthesise "Baygın Zurna": a funny ringtone where the zurna gets dizzy and faints.
  1. Wedding start: davul, dem drone, zurna fanfare and the Bergamota Mi melody.
  2. Dizziness: the zurna wobbles, notes sag flat, tempo drags 118 -> 66 BPM,
     hiccups ("hık!") cut into the line and the davul starts missing beats.
  3. Faint: a long sliding "vuuuu" two octaves down, the dem deflates, the davul
     plays the fall ("güm ... tak, güm").
  4. Silence, one hiccup, then the zurna wakes up and finishes at 140 BPM.
Reuses the zurna and davul voices from make_zurna_ringtone.py."""
import sys, wave
import numpy as np
from make_mi_ringtone import SR, hz, reverb, LEAD
from make_zurna_ringtone import zurna_line, tokmak, cubuk, upper_of, down

rng = np.random.default_rng(1071)

DIZZY_FROM, DIZZY_FULL = 16, 40      # beats
FAINT, FAINT_SECS = 40, 3.0          # faint starts at beat 40 and slides for 3 s
WAKE = 46                            # revival starts here


def tempo(b):
    if b < 24: return 118.0
    if b < FAINT: return 118 - (b - 24) / (FAINT - 24) * 52
    if b < WAKE: return 60.0
    return 140.0


GRID = np.arange(0, 60, 1/96)
SECS = np.concatenate([[0], np.cumsum(60.0 / np.array([tempo(b) for b in GRID[:-1]]) / 96)])


def sec(beat):
    return float(np.interp(beat, GRID, SECS))


def dizzy(beat):
    return float(np.clip((beat - DIZZY_FROM) / (DIZZY_FULL - DIZZY_FROM), 0, 1))


def note_ev(beat, beats, note, acc=1):
    s = sec(beat)
    return (s, sec(beat + beats) - s, hz(note), acc)


def ornament(beat, beats, note, upper, out):
    """Grace note from above + trill at the end of long notes (in beats)."""
    g = 0.12 * tempo(beat) / 118 if beats >= 0.75 else 0
    if g:
        out.append(note_ev(beat, g, upper))
    trill = beats >= 1.5
    out.append(note_ev(beat + g, beats - g - (0.5 if trill else 0), note, 0 if g else 1))
    if trill:
        for i in range(6):
            out.append(note_ev(beat + beats - 0.5 + i/12, 1/12, upper if i % 2 == 0 else note, 0))


def main(out_wav):
    total = sec(WAKE + 9) + 2.0
    n = int(total * SR)
    t = np.arange(n) / SR
    beat_of = np.interp(t, SECS, GRID)
    dz = np.clip((beat_of - DIZZY_FROM) / (DIZZY_FULL - DIZZY_FROM), 0, 1)

    # ---------------- zurna lead
    ev, sags = [], []
    for i, nt in enumerate(['D4', 'E4', 'F#4', 'G4', 'A4', 'B4', 'C#5']):
        ev.append(note_ev(4 + i*0.25, 0.25, nt))
    ornament(5.75, 2.25, 'D5', 'E5', ev)
    pos = 8
    for bar in LEAD:
        for nt, l in bar:
            if nt:
                z = down(nt)
                ornament(pos, l, z, upper_of(z), ev)
                if l >= 0.5 and dizzy(pos) > 0:
                    sags.append((sec(pos), sec(pos + l), dizzy(pos)))
            pos += l
    # hiccups cutting into the line ("hık!")
    for hb in (29.5, 35.75, 38.6):
        ev.append(note_ev(hb, 0.07 * tempo(hb) / 60, 'B6'))
    # faint: one long D5 that slides away
    fs, fe = sec(FAINT), sec(FAINT) + FAINT_SECS
    ev.append((fs, FAINT_SECS, hz('D5'), 1))
    # wake-up hiccup, then revival at 140 BPM
    ev.append(note_ev(WAKE - 0.75, 0.15, 'B6'))
    for i, nt in enumerate(['D4', 'E4', 'F#4', 'G4', 'A4', 'B4', 'C#5']):
        ev.append(note_ev(WAKE + i*0.25, 0.25, nt))
    ornament(WAKE + 1.75, 2.25, 'D5', 'E5', ev)
    for i, nt in enumerate(['A5', 'G5', 'F#5', 'E5']):
        ev.append(note_ev(WAKE + 4 + i*0.25, 0.25, nt))
    ornament(WAKE + 5, 2, 'D5', 'E5', ev)
    ev.append(note_ev(WAKE + 7, 0.6, 'A5'))

    # pitch bend: seasick wobble + flat drift + sagging note ends + the faint slide
    bend = dz**1.5 * 0.07 * np.sin(2*np.pi*1.3*t) + dz * 0.03 * np.sin(2*np.pi*0.37*t) - dz * 0.04
    for a, b, d in sags:
        i, j = int(a*SR), int(b*SR)
        x = np.linspace(0, 1, j - i)
        bend[i:j] -= 0.13 * d * x**2
    i, j = int(fs*SR), int(fe*SR)
    x = np.linspace(0, 1, j - i)
    bend[i:j] = -2.0 * x**1.6 + 0.07 * (1 - x) * np.sin(2*np.pi*1.3*t[i:j]) - 0.04
    bend[j:] = 0
    bend = np.convolve(bend, np.ones(441)/441, 'same')
    gain = np.ones(n)
    gain[i:j] = 1 - x**2.5
    gain[j:int(sec(WAKE - 1)*SR)] = 0
    lead = zurna_line(ev, total, bend=bend, gain=gain)

    # ---------------- dem drone: drifts with the zurna, deflates when it faints
    dem_ev = [(sec(0.5), fs + 1.6 - sec(0.5), hz('D4'), 0), (sec(WAKE), total - sec(WAKE) - 1.5, hz('D4'), 0)]
    dbend = dz * (-0.05) + dz**1.5 * 0.04 * np.sin(2*np.pi*0.9*t + 1)
    k = int(fs*SR); m = int((fs + 1.6)*SR)
    y = np.linspace(0, 1, m - k)
    dbend[k:m] = -0.05 - 1.0 * y**1.3
    dbend[m:] = 0
    dgain = np.ones(n); dgain[k:m] = 1 - y**1.5
    dem = zurna_line(dem_ev, total, vib_rate=4.9, bend=np.convolve(dbend, np.ones(441)/441, 'same'), gain=dgain) * 0.28

    # ---------------- davul
    dav = np.zeros(n)

    def hit(sig, beat, g=1.0, jitter=0.0):
        s = sec(beat) + jitter
        a = int(s * SR); L = min(len(sig), n - a)
        if L > 0: dav[a:a+L] += sig[:L] * g

    for bar in range(FAINT // 4):
        b0 = bar * 4
        for b, kind in ((0, 1), (1, 0), (1.5, 1), (2, 0), (2.5, 1), (3, 0), (3.5, 0)):
            d = dizzy(b0 + b)
            if d and rng.random() < d * 0.4:      # the drummer is getting dizzy too
                continue
            j = rng.normal(0, d * 0.04)
            hit(tokmak() if kind else cubuk(), b0 + b, 1.0, j)
        if dizzy(b0) < 0.3:
            for b in np.arange(0, 4, 0.25):
                hit(cubuk(0.3), b0 + b + 0.125)
        if bar == 1:
            for q in range(8):
                hit(cubuk(0.5 + q*0.07), b0 + 3 + q/8)
    # the fall: big low boom, the zurna hits the floor, small bounce
    hit(tokmak(), FAINT, 1.0)
    thud = fe - 0.05
    for off, sig, g in ((0, tokmak(), 1.7), (0.13, cubuk(1.4), 1.0), (0.32, tokmak(), 0.5), (0.45, cubuk(0.6), 1.0)):
        a = int((thud + off) * SR); L = min(len(sig), n - a); dav[a:a+L] += sig[:L] * g
    # revival groove + roll + final hit
    for bar in range(2):
        b0 = WAKE + bar * 4
        for b in (0, 1.5, 2.5):
            hit(tokmak(), b0 + b)
        for b in np.arange(0, 4, 0.5):
            hit(cubuk(0.9), b0 + b + 0.25)
    for q in range(12):
        hit(cubuk(0.5 + q*0.05), WAKE + 7 + q/12)
    hit(tokmak(), WAKE + 8, 1.4); hit(cubuk(1.2), WAKE + 8)

    L = 0.95*lead + 0.75*dem + 0.9*dav
    R = 0.95*lead + 1.05*dem + 0.9*dav
    L = L + 0.18*reverb(L, 5, 1.1); R = R + 0.18*reverb(R, 6, 1.1)
    stop = int((sec(WAKE + 8) + 1.4) * SR)
    L, R = L[:stop], R[:stop]
    pk = max(abs(L).max(), abs(R).max())
    L, R = np.tanh(1.4*L/pk)/np.tanh(1.4)*0.92, np.tanh(1.4*R/pk)/np.tanh(1.4)*0.92
    f = int(0.6*SR); fade = np.linspace(1, 0, f)**2
    L[-f:] *= fade; R[-f:] *= fade
    pcm = (np.stack([L, R], 1)*32767).astype('<i2')
    with wave.open(out_wav, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{out_wav}: {stop/SR:.1f}s  (faint at {fs:.1f}s, wake at {sec(WAKE):.1f}s)")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'baygin.wav')
