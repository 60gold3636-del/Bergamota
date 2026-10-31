"""Android tarafı için yt-dlp sarmalayıcı (ffmpeg yok: birleştirme gerektirmeyen formatlar)."""
import os

import yt_dlp


def indir(link, ses, klasor, geri):
    def kanca(d):
        if d["status"] == "downloading":
            toplam = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            inen = d.get("downloaded_bytes") or 0
            oran = inen / toplam if toplam else -1.0
            hiz = (d.get("_speed_str") or "").strip()
            geri.ilerleme(float(oran), hiz)
        elif d["status"] == "finished":
            geri.ilerleme(1.0, "")

    if ses:
        fmt = "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b"
    else:
        # ffmpeg olmadığı için görüntü+ses tek dosyada olan en iyi formatı seç
        fmt = "b[ext=mp4][vcodec!=none][acodec!=none]/b[vcodec!=none][acodec!=none]/b"

    secenek = {
        "format": fmt,
        "outtmpl": os.path.join(klasor, "%(title).80B [%(id)s].%(ext)s"),
        "windowsfilenames": True,
        "noplaylist": True,
        "retries": 5,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "progress_hooks": [kanca],
    }
    with yt_dlp.YoutubeDL(secenek) as ydl:
        bilgi = ydl.extract_info(link, download=True)
        girdiler = bilgi.get("entries") or [bilgi]
        yollar = []
        for g in girdiler:
            if not g:
                continue
            for r in g.get("requested_downloads") or []:
                if r.get("filepath"):
                    yollar.append(r["filepath"])
        return yollar


def surum():
    return yt_dlp.version.__version__
