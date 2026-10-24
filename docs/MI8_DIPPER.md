# Xiaomi Mi 8 (`dipper`) portu

Bergamota'nın Poco F1 (`beryllium`) için yaptığı iOS 18 açılışını Xiaomi Mi 8'e taşır. İki telefonda
da Snapdragon 845 var, ayrılmış bellek düzenleri (`dipper-p0.dtsi` = `beryllium-p0.dtsi`) ve PMIC'leri
aynı. Bu yüzden Mi 8, Poco F1'in bütün SDM845 kodunu (UFS, USB, PMIC, pil, WCN3990, A630, cpufreq)
olduğu gibi kullanır. Farklı olan yalnızca ekran ve dokunmatik.

> Durum: kod yazıldı ve bilgisayarda doğrulandı, **cihazda henüz test edilmedi**. Poco F1'de de
> çalışmayanlar (Wi-Fi, hücresel, ses, kamera, sensörler, GPU hızlandırma) Mi 8'de de çalışmaz.

## Donanım farkları (LineageOS `android_kernel_xiaomi_sdm845`, dal lineage-22.2)

| | Poco F1 (beryllium) | Mi 8 (dipper) |
| --- | --- | --- |
| Panel | Tianma NT36672A / EBBG FT8719 LCD, **video modu**, 1080x2246, WLED arka ışık | Samsung EA8074 AMOLED, **komut modu** (TE: TLMM 10), 1080x2248, WLED yok |
| Dokunmatik | NT36672A @0x01 veya FT8719 @0x38 | **ST FTM5 @0x49** (`st,fts`, sürücü `fts_521`) |
| Dokunmatik veri yolu | I2C14 = QUP SE14 @0xa98000, IRQ TLMM 31, reset TLMM 32, SDA/SCL 33/34 | aynı |
| Dokunmatik gücü | panel rayları | AVDD L28A 3.3 V (`regulator-boot-on`), VDD panel VDDIO |
| Splash bellek | 0x9d400000, 0x2400000 | aynı |
| Ses+ tuşu | PM8998 GPIO6 | aynı |
| Pil | 4000 mAh | 3400 mAh |
| DTB board-id | 0x45 ("Beryllium MP v2.1") | 0x37 ("Dipper new MP v2.1") |

## Yapılan değişiklikler

- `xnu/patches-11215/0200-dipper-board-touch-display-battery.patch` (çekirdek):
  - `sweet_board_dipper()`: ADT `compatible` içinde `xiaomi,dipper`. Mi 8'in ADT'si `xiaomi,beryllium`
    da içerir, böylece bütün beryllium yolları aynen çalışır.
  - Dokunmatik: ST FTM5 sürücüsü (`touch_dipper_start`, `touch_ftm5`). Reset pinine darbe verir,
    `CONTROLLER_READY` (0x03) olayını bekler, `A0 00 01` ile algılamayı açar, 0x86 ile 8 baytlık
    olayları okur (0x13 giriş, 0x23 hareket, 0x33 çıkış). IRQ seviye tetiklidir (FIFO doluyken düşük).
    Çipe ürün yazılımı yüklenmez.
  - Ekran: komut modu paneli yalnızca MDP'den kare geldiğinde güncellenir. `sweetfb_cmd` önyükleme
    argümanı: `1` (varsayılan) ABL'nin tear-check açtığı PINGPONG bloğunda autorefresh'i açar
    (her TE'de bir kare) ve çalıştığını satır sayacıyla doğrular. Çalışmazsa kendiliğinden `2`ye
    düşer: her flush'tan sonra `CTL_START` (bu mod `sweetfb_flip=1` ister). `0` hiçbir şey yapmaz.
  - WLED arka ışık solması Mi 8'de devre dışıdır (AMOLED'de WLED yok); ekran kapatma piksel yoluyla
    (siyah kare) yapılır.
  - Pil kapasitesi 3400 mAh olarak bildirilir.
- `enxerto/`: `BOARD=dipper` (beryllium + `BOARD_DIPPER`): 1080x2248 framebuffer. Açılışta aynı
  autorefresh açılır, böylece Enxerto ekranları (logo, fastboot, şarj) komut modu panelde görünür.
- `tools/mkadt.py --board dipper`, `BOARD=dipper tools/renegade/mkboot-full.sh`.

## Bilgisayarda doğrulananlar (2026-10-23)

- Tüm yama yığını, yeni yamayla birlikte, saf `xnu-11215.81.4` üzerine uygulanıyor (CI ile aynı
  sırada). Başarısız olan 5 yama değişmedi ve beklenen yamalar: HFS yamaları `stage-hfs.sh`'tan
  sonra uygulanır, dxb'nin iki yaması bu xnu sürümüne ait değil.
- `sweet_touch.c` taslak çekirdek başlıklarıyla `-Wall -Wextra` uyarısız derleniyor.
- Dosyadan çıkarılan gerçek `touch_ftm5()` sahte bir FTM5 FIFO'suyla test edildi: tek ve çoklu
  parmak, köşe koordinatları, hover, sınır dışı değerler, boş FIFO, 10'dan uzun olay dizisi.
- Enxerto, `BOARD=dipper` ve `BOARD=beryllium` için derleniyor. Fastboot testleri 485/485 geçiyor.
  Dipper imajında 2248 ve MDP kodu var; beryllium imajı değişmedi.
- `mkadt.py --board dipper`: `compatible = D22AP|iPhone10,3|xiaomi,dipper|xiaomi,beryllium|...`,
  `sweet-fbcon` yüksekliği 0x8c8 (2248).
- `SweetFramebuffer.cpp` ve `SweetBattery.cpp` yerelde derlenmedi; ilk gerçek derleme CI'da olacak.

## Gerekenler

- Bootloader kilidi açık bir Mi 8.
- Çekirdek: GitHub hesabında bu deponun bir fork'u. Çekirdek `.github/workflows/xnu.yml` ile macOS
  sunucularında derlenir. Yapılandırma `SWEET` olarak kalır; kart çalışma anında ADT'den seçilir.
- Kök imaj (`renegade fetch` / `renegade root`): **macOS gerekir** (`hdiutil`, `codesign`, `xcrun`).
  Bir Mac ya da macOS CI sunucusu ve yaklaşık 20 GB boş alan.
- Enxerto ve ADT: Linux/WSL'de yapılabilir. Sudo gerekmez: ARM GNU `aarch64-none-elf` 13.3 araç
  zinciri ve Ubuntu'nun `cpio`, `mkbootimg`, `device-tree-compiler` paketleri (`apt-get download` +
  `dpkg-deb -x`), `CROSS=aarch64-none-elf-`.

## Adımlar

### 1. aşama: geçici açılış (telefona hiçbir şey yazılmaz)

1. DTB'yi Mi 8'in boot.img dosyasından çıkarın (resmi MIUI fastboot ROM'u ya da LineageOS boot.img):
   `python3 tools/extract-dtb.py boot.img dtb/dipper`. "Dipper new MP v2.1" (board-id 0x37) seçilir;
   gerekirse `--pick N`.
2. `BOARD=dipper enxerto/build.sh` komutu `enxerto/out/bergamota-fastboot.img` dosyasını üretir.
3. Telefon fastboot modundayken: `fastboot boot enxerto/out/bergamota-fastboot.img`. Bergamota
   fastboot ekranı görünmelidir. Görünmüyorsa komut modu yenilemesi çalışmıyordur; bu ilk hedeftir.
   Yeniden başlatınca kurulu sistem (örneğin ColorOS) aynen açılır.

### 2. aşama: tam iOS (`userdata` silinir)

1. Kritik bölümleri yedekleyin (persist, modem, bluetooth, dsp, EFS/modemst1/modemst2/fsg/fsc, boot).
2. Mac'te kök imajı oluşturun (`renegade fetch`, ardından `renegade root`). Bkz. `docs/IOS18_PORT.md`.
3. `python3 tools/mkadt.py enxerto/out/dipper-hi-3x.adt --board dipper --highmem --display-scale 3`
4. `BOARD=dipper tools/renegade/mkboot-full.sh <kernel> enxerto/out/dipper-hi-3x.adt`
5. Kök imajı yazın: `python3 tools/bergamota-flash.py flash userdata research/ios18/ios18-root-full.simg`.
   Bu, `userdata` içindeki Android verilerini siler. Android'in sistem bölümleri yerinde kalır;
   `userdata` biçimlendirildiğinde Android temiz kurulum gibi açılır.
6. `fastboot boot research/ios18/enxerto-boot-ios18full.img`. İlk açılış birkaç dakika sürer.

`--highmem` 6 GB RAM'e göre ayarlıdır (0x1_00000000 + 0xfcc00000). Farklı RAM'li bir modelde
`/sys/firmware/fdt` içindeki memory düğümüyle karşılaştırın.

## Hata ayıklama için önyükleme argümanları

| Argüman | Anlamı |
| --- | --- |
| `sweetfb_cmd=0/1/2` | komut modu yenilemesi: kapalı / autorefresh (varsayılan) / her flush'ta CTL_START |
| `sweettouchlog=1` | her FTM5 olayını `F5 ..` satırı olarak günlüğe yazar |
| `sweettouchdelay=N` | dokunmatik N saniye sonra başlar (varsayılan 45) |
| `sweettouch=0` | dokunmatiği kapatır |

Çekirdek günlüğünde bakılacaklar: `SWEET MDP: PPn autorefresh on`, `SWEET MDP: CTLn top ...`
(CTL0 dışında bir CTL etkinse henüz desteklenmiyor), `SWEET TOUCH: ftm5 reset ... err=0`,
`SWEET TOUCH: selected ST FTM5, 1080x2248`.

## Bilinen riskler ve açık noktalar

- Komut modu yenilemesi, ABL'nin CTL0 ve tear-check'li bir PINGPONG kullandığı varsayımına dayanır.
  Çekirdek günlüğü bunu doğrular.
- AMOLED parlaklığı DCS komutuyla ayarlanır; parlaklık kontrolü yok, ABL'nin bıraktığı seviye kalır.
- Bu çekirdekte panel uyku komutu (DCS) yok. "Ekran kapalı" siyah bir karedir; AMOLED'de siyah
  pikseller neredeyse hiç güç harcamaz.
