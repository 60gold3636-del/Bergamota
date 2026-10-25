import sys, wave
sys.path.insert(0, '/home/user/Bergamota/ringtone')
import numpy as np
from make_mi_ringtone import SR, hz, reverb
from make_zurna_ringtone import zurna_line

# Hicaz on D (D Eb F# G A Bb C D), free taksim-like phrase: (note, seconds)
P = [('D5',0.9),('Eb5',0.12),('D5',0.5),('C5',0.25),('Bb4',0.25),('A4',1.1),(None,0.15),
     ('A4',0.2),('Bb4',0.2),('C5',0.2),('D5',0.2),('Eb5',0.2),('F#5',0.25),('G5',1.2),
     ('F#5',0.2),('Eb5',0.2),('D5',0.3),('C5',0.2),('Bb4',0.2),('A4',0.8),
     ('Bb4',0.15),('A4',0.15),('G4',0.2),('F#4',0.3),('Eb4',0.3),('D4',2.0)]
ev, t = [], 0.4
for i,(n,d) in enumerate(P):
    if n:
        ev.append((t, d, hz(n), 1))
        if d >= 1.0:   # trill near the end of long notes
            up = {'D5':'Eb5','A4':'Bb4','G5':'A5','D4':'Eb4'}[n]
            for k in range(8):
                ev.append((t+d-0.45+k*0.05, 0.05, hz(up if k%2==0 else n), 0))
    t += d
total = t + 1.5
lead = zurna_line(ev, total)
dem = zurna_line([(0.0, total-1.0, hz('D4'), 0)], total, vib_rate=4.9) * 0.25
L = lead + 0.8*dem; R = lead + 1.1*dem
L = L + 0.15*reverb(L, 3, 1.0); R = R + 0.15*reverb(R, 4, 1.0)
pk = max(abs(L).max(), abs(R).max()); L, R = L/pk*0.9, R/pk*0.9
f = int(0.8*SR); L[-f:] *= np.linspace(1,0,f)**2; R[-f:] *= np.linspace(1,0,f)**2
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((np.stack([L,R],1)*32767).astype('<i2').tobytes())
print(f"{total:.1f}s")
