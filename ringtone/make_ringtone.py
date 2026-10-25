#!/usr/bin/env python3
"""Synthesise "Bergamota Blend", a funny ringtone mixing three phone moods:
  - iPhone mood: soft marimba timbre with a bouncy arpeggio (original notes)
  - Samsung mood: bright, rising "over the horizon"-style synth chords (original notes)
  - Nokia: the Gran Vals motif (Francisco Tarrega, 1902, public domain),
    played first on marimba, then as a squeaky 3310-style square-wave beep.
Pure numpy; writes a 44.1 kHz mono WAV. No samples are used."""
import sys, wave
import numpy as np

SR = 44100
BPM = 132
E = 60.0 / BPM / 2          # one eighth note in seconds


def hz(note):
    names = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
    n = names[note[0]]
    i = 1
    if note[i] == '#':
        n += 1; i += 1
    elif note[i] == 'b':
        n -= 1; i += 1
    octave = int(note[i:])
    return 440.0 * 2 ** ((n + 12 * (octave + 1) - 69) / 12)


def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def marimba(f, dur=0.6):
    t = t_axis(dur)
    env = np.exp(-t * 9)
    s = np.sin(2*np.pi*f*t) + 0.35*np.sin(2*np.pi*4*f*t)*np.exp(-t*30) \
        + 0.12*np.sin(2*np.pi*10*f*t)*np.exp(-t*60)
    attack = np.minimum(1, t / 0.002)
    return s * env * attack * 0.5


def square_beep(f, dur):
    t = t_axis(dur)
    s = np.sign(np.sin(2*np.pi*f*t)) * 0.18
    rel = np.minimum(1, (dur - t) / 0.01)
    return s * np.clip(rel, 0, 1)


def bright_pluck(f, dur=0.5):
    # detuned saws with a fast low-pass sweep feel (approximated by decaying harmonics)
    t = t_axis(dur)
    s = np.zeros_like(t)
    for k in range(1, 14):
        s += np.sin(2*np.pi*k*f*1.003*t) / k * np.exp(-t*(3 + k*1.5))
        s += np.sin(2*np.pi*k*f*0.997*t) / k * np.exp(-t*(3 + k*1.5))
    return s * np.minimum(1, t/0.004) * 0.12


def pad(freqs, dur):
    t = t_axis(dur)
    s = sum(np.sin(2*np.pi*f*t) + 0.3*np.sin(2*np.pi*2*f*t) for f in freqs)
    env = np.minimum(1, t/0.15) * np.minimum(1, (dur - t)/0.2)
    return s * np.clip(env, 0, 1) * 0.05


def boing(dur=0.35, f0=180, f1=520):
    t = t_axis(dur)
    f = f0 + (f1 - f0) * (1 - np.exp(-t*14)) + 25*np.sin(2*np.pi*18*t)*np.exp(-t*6)
    ph = 2*np.pi*np.cumsum(f)/SR
    return np.sin(ph) * np.exp(-t*7) * 0.35


def slide_whistle(dur, f0, f1):
    t = t_axis(dur)
    f = np.geomspace(f0, f1, len(t)) * (1 + 0.01*np.sin(2*np.pi*6*t))
    ph = 2*np.pi*np.cumsum(f)/SR
    env = np.minimum(1, t/0.03) * np.minimum(1, (dur-t)/0.05)
    return (np.sin(ph) + 0.1*np.sin(2*ph)) * np.clip(env, 0, 1) * 0.22


def kick(dur=0.25):
    t = t_axis(dur)
    ph = 2*np.pi*np.cumsum(50 + 110*np.exp(-t*30))/SR
    return np.sin(ph) * np.exp(-t*12) * 0.5


def clap(dur=0.15):
    t = t_axis(dur)
    rng = np.random.default_rng(7)
    return rng.standard_normal(len(t)) * np.exp(-t*35) * 0.15


def honk(dur=0.3, f=233):
    t = t_axis(dur)
    s = sum(np.sign(np.sin(2*np.pi*f*k*t)) / k for k in (1, 1.5, 2))
    return s * np.exp(-t*4) * np.minimum(1, t/0.01) * 0.1


class Track:
    def __init__(self, length):
        self.buf = np.zeros(int(length * SR) + SR)

    def add(self, sig, at):
        i = int(at * SR)
        self.buf[i:i+len(sig)] += sig[:len(self.buf)-i]


# Nokia / Gran Vals motif in A major, (note, length in eighths)
NOKIA = [('E6', 1), ('D6', 1), ('F#5', 2), ('G#5', 2),
         ('C#6', 1), ('B5', 1), ('D5', 2), ('E5', 2),
         ('B5', 1), ('A5', 1), ('C#5', 2), ('E5', 2), ('A5', 6)]


def main(out):
    tr = Track(26)
    t = 0.0

    # 1) iPhone mood: bouncy marimba arpeggios over A - E - F#m - D
    arps = [['A4', 'E5', 'A5', 'C#6'], ['G#4', 'E5', 'B5', 'E6'],
            ['A4', 'C#5', 'F#5', 'A5'], ['F#4', 'D5', 'A5', 'D6']]
    for chord in arps:
        for rep in range(2):
            for k, n in enumerate(chord):
                tr.add(marimba(hz(n)), t + (rep*4 + k) * E * 0.5)
        t += 4 * E
    tr.add(boing(), t - E*0.5)

    # 2) Nokia motif on marimba, with a light kick/clap groove
    def groove(start, bars):
        for b in range(bars * 4):
            tr.add(kick(), start + b * 2 * E)
            if b % 2:
                tr.add(clap(), start + b * 2 * E)
    groove(t, 3)
    for n, l in NOKIA:
        tr.add(marimba(hz(n), 0.5 + 0.1*l), t)
        t += l * E
    tr.add(slide_whistle(0.45, 600, 1800), t - 0.45)

    # 3) Same motif, double speed and an octave up on a squeaky 3310 beep (the funny bit)
    for n, l in NOKIA:
        f = hz(n) * 2
        d = l * E / 2
        tr.add(square_beep(f, d * 0.85), t)
        t += d
    tr.add(honk(), t); tr.add(honk(f=196), t + 0.18)
    t += 2 * E

    # 4) Samsung mood: bright, rising "horizon" chords and a hopeful pluck melody
    prog = [(['A3', 'C#4', 'E4'], ['E5', 'A5', 'C#6', 'B5']),
            (['E3', 'G#3', 'B3'], ['B5', 'G#5', 'E5', 'G#5']),
            (['F#3', 'A3', 'C#4'], ['C#6', 'A5', 'F#5', 'A5']),
            (['D3', 'F#3', 'A3'], ['D6', 'E6', 'F#6', 'A6'])]
    groove(t, 4)
    for chord, mel in prog:
        bar = 8 * E
        tr.add(pad([hz(n) for n in chord] + [hz(n)*2 for n in chord], bar), t)
        for k, n in enumerate(mel):
            tr.add(bright_pluck(hz(n), 0.6), t + k * 2 * E)
            tr.add(bright_pluck(hz(n) * 2, 0.3) * 0.4, t + k * 2 * E + E)
        t += bar

    # 5) Finale: Nokia tag on marimba + bright pluck together, then boing
    for n, l in NOKIA[-5:]:
        tr.add(marimba(hz(n)), t); tr.add(bright_pluck(hz(n), 0.4) * 0.6, t)
        t += l * E * (1 if l < 6 else 0.5)
    tr.add(pad([hz('A3'), hz('C#4'), hz('E4'), hz('A4')], 1.4), t - 3*E)
    tr.add(boing(0.5, 300, 900), t)
    t += 0.7

    s = tr.buf[:int(t * SR)]
    # gentle reverb-ish echo
    d = int(0.11 * SR)
    wet = np.zeros_like(s); wet[d:] += s[:-d] * 0.25; wet[2*d:] += s[:-2*d] * 0.1
    s = s + wet
    s = np.tanh(s * 1.3)
    s /= np.max(np.abs(s)) / 0.89
    fade = int(0.05 * SR); s[-fade:] *= np.linspace(1, 0, fade)
    pcm = (s * 32767).astype('<i2')
    with wave.open(out, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{out}: {t:.1f}s")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'ringtone.wav')
