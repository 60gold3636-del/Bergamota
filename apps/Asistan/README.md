# Asistan — internetsiz Türkçe sesli asistan (Android)

Siri / "OK Google" yerine: konuşma tanıma **telefonun içinde** (Vosk, Türkçe model) yapılır,
bu yüzden arama, alarm, zamanlayıcı, fener, uygulama açma gibi komutlar internet olmadan çalışır.
Hava durumu ve yol tarifi için internet gerekir (Open-Meteo, anahtar gerektirmez).

## Kurulum
1. APK: GitHub'da **Releases → asistan-latest → Asistan.apk** (her derlemede güncellenir) ya da
   Actions → "Asistan APK" çalıştırmasının `Asistan-apk` dosyası.
2. Telefonda "bilinmeyen kaynaklardan yükleme"ye izin verip kurun.
3. Uygulamayı açın: **İzinleri ver**, **Üstte göster izni** (arka planda alarm/uygulama açmak için),
   **Pil optimizasyonundan çıkar** (Android dinlemeyi kapatmasın).
4. **Asistanı başlat**. Bildirim çubuğunda "Asistan — Dinliyor" görünür.
5. Türkçe sesli yanıt için: Ayarlar → Metin okuma çıkışı → Google TTS → Türkçe ses verisini indirin.

## Kullanım
"**asistan**" deyin, bip sesinden sonra komutu söyleyin; ya da tek cümlede: "asistan eşimi ara".

| Komut | Örnek |
|---|---|
| Arama | eşimi ara, annemi ara, Ahmet'i ara |
| Alarm | yarın sabah sekize alarm kur, akşam yedi buçuğa alarm kur, on dakika sonraya alarm kur |
| Zamanlayıcı | beş dakikalık zamanlayıcı kur, yarım saat sonra haber ver |
| Hava | bugün hava nasıl, yarın hava nasıl, İzmir'de hava nasıl |
| Bilgi | saat kaç, bugün günlerden ne, şarj kaç |
| Fener | feneri aç / kapat |
| Ses / müzik | sesi aç, sesi kıs, sessize al, müziği durdur, sonraki şarkı |
| Uygulama | kamerayı aç, WhatsApp'ı aç |
| Yol tarifi | Kadıköy'e yol tarifi |
| Durdur | sus, iptal |

"Eşim", "annem" gibi takma adlar: uygulamada takma adı yazıp **Rehberden kişi seç**.
Ana ekran tuşuna uzun basma / kulaklık tuşu: Ayarlar → Varsayılan uygulamalar → Dijital asistan
uygulaması bölümünde Asistan seçilebiliyorsa, tek komut için dinlemeye başlar.

## Yapı
- `AssistantService` — ön plan servisi, mikrofonu sürekli dinler (Vosk), uyandırma kelimesini arar.
- `CommandParser`, `TrTime`, `Tr` — Türkçe komut, sayı ve saat ayrıştırma ("dokuza çeyrek var", "bir buçuk saat").
- `Assistant` — komutları uygular (TelecomManager ile arama, AlarmClock, CameraManager, Open-Meteo…).
- Konuşma modeli (`vosk-model-small-tr-0.3`, ~35 MB) git'te değil; CI derlemede indirip APK'ya koyar.
  Yerelde derlemek için modeli `app/src/main/assets/model-tr/` altına açıp içine `uuid` dosyası yazın.
- `app/asistan.keystore` (parola `asistan`) sabit imza anahtarıdır: her yeni APK öncekinin üzerine kurulur.
  Gizli değildir; depoya erişen herkes bu anahtarla imzalayabilir.

## Bilinen sınırlar
- Küçük Türkçe model gürültülü ortamda hata yapabilir; isimler rehberle bulanık eşleştirilir ve
  asistan ne yaptığını sesli söyler ("Ayşe aranıyor").
- Android 14+, telefon açılışında mikrofon servisini otomatik başlatmaya izin vermez: yeniden başlatmadan
  sonra uygulamayı bir kez açıp "Asistanı başlat"a basın.
- "Yarın" için alarm saat uygulamasına saat/dakika olarak gider; saat uygulaması bir sonraki o saatte çalar.
