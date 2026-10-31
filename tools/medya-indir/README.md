# medya-indir

Sosyal medya linklerinden **video** veya **ses** indiren basit araç
(YouTube, Instagram, TikTok, X/Twitter, Facebook, Reddit, Vimeo, SoundCloud ve
[yt-dlp](https://github.com/yt-dlp/yt-dlp)'nin desteklediği diğer siteler).

## Kurulum
```
pip install -U yt-dlp
```
ffmpeg de gerekli: Windows `winget install ffmpeg`, macOS `brew install ffmpeg`,
Linux `sudo apt install ffmpeg`.

## Kullanım
```
python3 medya_indir.py                      # soru-cevaplı mod
python3 medya_indir.py LINK                 # video (en iyi kalite, mp4)
python3 medya_indir.py -s LINK              # yalnızca ses (mp3, kapak resimli)
python3 medya_indir.py -s -f m4a LINK       # ses, m4a formatında
python3 medya_indir.py -k 720 LINK1 LINK2   # en fazla 720p
python3 medya_indir.py -l linkler.txt       # dosyadaki tüm linkler
python3 medya_indir.py -p LINK              # oynatma listesinin tamamı
python3 medya_indir.py -c chrome LINK       # giriş gerektiren içerik (tarayıcı çerezleri)
python3 medya_indir.py -o ~/Muzik -s LINK   # farklı kayıt klasörü
```
Dosyalar varsayılan olarak `./indirilenler/video/` ve `./indirilenler/ses/` klasörlerine kaydedilir.

Bir site çalışmayı bırakırsa önce `pip install -U yt-dlp` ile güncelleyin.
Yalnızca indirme hakkınız olan içerikleri indirin.
