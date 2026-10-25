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
