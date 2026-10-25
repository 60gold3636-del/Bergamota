# Bergamota Blend ringtone

Funny ~22 s ringtone, synthesised from scratch by `make_ringtone.py` (numpy only, no samples):

1. iPhone mood – bouncy marimba arpeggios (original notes)
2. Nokia tune – Tárrega's *Gran Vals* motif (public domain) on marimba
3. Same motif at double speed as a squeaky 3310-style beep + clown honks
4. Samsung mood – bright, rising "horizon" synth chords (original notes)
5. Finale – Nokia tag on marimba + synth, cartoon boing

Files:
- `BergamotaBlend-Magisk-v1.0.zip` – install from Magisk app > Modules > Install from storage, reboot,
  then pick **BergamotaBlend** in Settings > Sounds > Ringtone.
- `BergamotaBlend.ogg` – plain audio file (works without root too).

Rebuild: `python3 make_ringtone.py out.wav && ffmpeg -i out.wav -c:a libvorbis -q:a 6 BergamotaBlend.ogg`

# Bergamota Mi ringtone

Original ~25 s Xiaomi/Redmi-style ringtone (`make_mi_ringtone.py`, stereo). The melody and
chords (Dadd9 – A/C# – Bm7 – Gmaj7 – Em7 – Cadd9 – A7sus4 – A7) are written from scratch.
Instruments: FM electric piano lead, FM glass bells, nylon pluck arpeggios, supersaw pad,
sub bass with extra harmonics for phone speakers, kick/clap/hat/shaker, convolution reverb.

- `BergamotaMi-Magisk-v1.0.zip` – Magisk module (separate id, can be installed next to Blend)
- `BergamotaMi.ogg` – plain audio file
