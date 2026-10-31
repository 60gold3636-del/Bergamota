#!/usr/bin/env python3
"""medya-indir: sosyal medya linklerinden video veya ses indirir.

YouTube, Instagram, TikTok, X/Twitter, Facebook, Reddit, Vimeo, SoundCloud
ve yt-dlp'nin desteklediği 1000+ siteyle çalışır.

Kullanım:
  python3 medya_indir.py                          # etkileşimli mod
  python3 medya_indir.py LINK [LINK ...]          # video (en iyi kalite, mp4)
  python3 medya_indir.py -s LINK                  # yalnızca ses (mp3)
  python3 medya_indir.py -s -f m4a LINK           # ses, m4a
  python3 medya_indir.py -k 720 LINK              # en fazla 720p video
  python3 medya_indir.py -l linkler.txt           # dosyadaki tüm linkler
  python3 medya_indir.py -c chrome LINK           # tarayıcı çerezleriyle
                                                  # (giriş gerektiren içerik)

Gereksinimler: pip install -U yt-dlp   ve sistemde ffmpeg.
Yalnızca indirme hakkınız olan içerikleri indirin.
"""
import argparse
import os
import shutil
import sys

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp bulunamadı. Kurmak için:  pip install -U yt-dlp")

SES_FORMATLARI = ("mp3", "m4a", "opus", "wav", "flac")


def secenekler(ses, fmt, kalite, klasor, cerez, liste):
    sablon = os.path.join(klasor, "ses" if ses else "video", "%(uploader|bilinmeyen)s - %(title).150B [%(id)s].%(ext)s")
    o = {
        "outtmpl": sablon,
        "noplaylist": not liste,
        "restrictfilenames": False,
        "windowsfilenames": True,
        "ignoreerrors": True,
        "retries": 5,
        "concurrent_fragment_downloads": 4,
        "progress_hooks": [ilerleme],
        "quiet": True,
        "noprogress": True,
        "no_warnings": True,
    }
    if cerez:
        o["cookiesfrombrowser"] = (cerez,)
    if ses:
        o["format"] = "bestaudio/best"
        o["postprocessors"] = [
            {"key": "FFmpegExtractAudio", "preferredcodec": fmt, "preferredquality": "0"},
            {"key": "FFmpegMetadata"},
        ]
        if fmt in ("mp3", "m4a", "flac", "opus"):
            o["writethumbnail"] = True
            o["postprocessors"].append({"key": "EmbedThumbnail"})
    else:
        h = f"[height<={kalite}]" if kalite else ""
        o["format"] = (
            f"bv*{h}[ext=mp4]+ba[ext=m4a]/bv*{h}+ba/b{h}/best"
        )
        o["merge_output_format"] = "mp4"
        o["postprocessors"] = [{"key": "FFmpegMetadata"}]
    return o


def ilerleme(d):
    if d["status"] == "downloading":
        yuzde = d.get("_percent_str", "").strip()
        hiz = d.get("_speed_str", "").strip()
        kalan = d.get("_eta_str", "").strip()
        print(f"\r  ⬇  {yuzde:>7}  {hiz:>11}  kalan {kalan:>8}", end="", flush=True)
    elif d["status"] == "finished":
        print("\r  ✔  indirildi, işleniyor...                    ")


def indir(linkler, args):
    o = secenekler(args.ses, args.format, args.kalite, args.klasor, args.cerez, args.liste)
    os.makedirs(args.klasor, exist_ok=True)
    basarisiz = []
    with yt_dlp.YoutubeDL(o) as ydl:
        for i, link in enumerate(linkler, 1):
            print(f"[{i}/{len(linkler)}] {link}")
            try:
                if ydl.download([link]) != 0:
                    basarisiz.append(link)
            except yt_dlp.utils.DownloadError as e:
                print(f"  ✘ hata: {e}")
                basarisiz.append(link)
    print(f"\nBitti. Kaydedilen klasör: {os.path.abspath(args.klasor)}")
    if basarisiz:
        print(f"{len(basarisiz)} link indirilemedi:")
        for l in basarisiz:
            print("  -", l)
        print("İpucu: giriş gerektiren içerik için  -c chrome  (veya firefox) deneyin;"
              " ayrıca  pip install -U yt-dlp  ile güncelleyin.")
    return 1 if basarisiz else 0


def etkilesimli(args):
    print("=== Medya İndirici ===  (çıkmak için boş bırakıp Enter)")
    linkler = []
    while True:
        l = input("Link: ").strip()
        if not l:
            break
        linkler.append(l)
    if not linkler:
        return 0
    secim = input("1) Video   2) Yalnızca ses  [1]: ").strip()
    args.ses = secim == "2"
    if args.ses:
        f = input(f"Ses formatı {'/'.join(SES_FORMATLARI)} [mp3]: ").strip().lower()
        args.format = f if f in SES_FORMATLARI else "mp3"
    else:
        k = input("En yüksek çözünürlük (ör. 1080, 720; boş = en iyi): ").strip()
        args.kalite = int(k) if k.isdigit() else None
    return indir(linkler, args)


def main():
    p = argparse.ArgumentParser(description="Sosyal medya linklerinden video/ses indirir (yt-dlp).")
    p.add_argument("linkler", nargs="*", help="indirilecek link(ler)")
    p.add_argument("-s", "--ses", action="store_true", help="yalnızca sesi indir")
    p.add_argument("-f", "--format", default="mp3", choices=SES_FORMATLARI, help="ses formatı (varsayılan mp3)")
    p.add_argument("-k", "--kalite", type=int, help="en yüksek video yüksekliği, ör. 720")
    p.add_argument("-o", "--klasor", default="indirilenler", help="kayıt klasörü (varsayılan ./indirilenler)")
    p.add_argument("-l", "--liste-dosyasi", help="her satırda bir link olan metin dosyası")
    p.add_argument("-c", "--cerez", metavar="TARAYICI", help="çerezleri bu tarayıcıdan al: chrome, firefox, edge, safari...")
    p.add_argument("-p", "--liste", action="store_true", help="oynatma listesinin/profilin tamamını indir")
    args = p.parse_args()

    if not shutil.which("ffmpeg"):
        print("Uyarı: ffmpeg bulunamadı; ses dönüştürme ve video+ses birleştirme çalışmaz.\n"
              "  Windows: winget install ffmpeg | macOS: brew install ffmpeg | Linux: apt install ffmpeg\n")

    linkler = list(args.linkler)
    if args.liste_dosyasi:
        with open(args.liste_dosyasi, encoding="utf-8") as fh:
            linkler += [s.strip() for s in fh if s.strip() and not s.startswith("#")]
    if not linkler:
        return etkilesimli(args)
    return indir(linkler, args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nİptal edildi.")
        sys.exit(130)
