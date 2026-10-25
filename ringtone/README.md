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

# Bergamota Mi Zurna ringtone

The Bergamota Mi melody (one octave down) on a synthesised zurna, with a second zurna holding
the dem (D drone) and a davul (tokmak + çubuk) playing a düm-tek groove with rolls, ~24 s.
Zurna ornaments: grace notes from the upper neighbour, trills on long notes, glides, vibrato.
Built by `make_zurna_ringtone.py` (imports helpers and the melody from `make_mi_ringtone.py`).

- `BergamotaMiZurna-Magisk-v1.0.zip` – Magisk module (own id, installs next to the others)
- `BergamotaMiZurna.ogg` – plain audio file

# Baygın Zurna ringtone

Funny ~34 s zurna story (`make_baygin_zurna_ringtone.py`): wedding start with the Bergamota Mi
melody, then the zurna gets dizzy (wobble, flat sagging notes, tempo dragging 118 -> 66 BPM,
hiccups, davul missing beats), faints with a two-octave slide while the dem deflates, the davul
plays the fall, and after a hiccup it wakes up and finishes at 140 BPM.

- `BayginZurna-Magisk-v1.0.zip` – Magisk module (own id)
- `BayginZurna.ogg` – plain audio file
