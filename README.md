# FPGA Tabanlı Gerçek Zamanlı Göz ve Göz Bebeği Takip Sistemi (Tang Nano 9K + OV7670 + HDMI)

Bilgisayar veya harici işlemci bağımlılığı olmadan, doğrudan **Sipeed Tang Nano 9K (`GW1NR-9C`)** FPGA üzerinde **OV7670** kameradan gerçek zamanlı görüntü alıp **2B Eşmerkezli Disk-Çevre (2D Concentric Disc-Surround)** algoritmasıyla göz bebeği (pupil) merkezini tespit eden ve çıktıyı **640x480 @ 60Hz HDMI** üzerinden sıfır gecikmeyle görüntüleyen donanım projesi.

Ayrıca kart üzerindeki **BL702 USB-UART (`COM7`, 921600 baud)** üzerinden hem **Donanım-Döngüde Test (Hardware-in-the-Loop / HIL)** video enjeksiyonu hem de HDMI monitör yokken bilgisayardan **~18 FPS Canlı Kamera & OSD İzleme** (`fpga_live_monitor.py`) desteği içerir.

---

## Öne Çıkan Özellikler

- **Tek Geçişli (Streaming) 2B Eşmerkezli Disk-Çevre Göz Bebeği Tespiti (`pupil_detector.v`)**:
  - **Yatay Glint (Kornea Yansıması) Köprüleme**: Göz bebeği üzerindeki parlak ışık yansımalarının koyu irisi bölmesini donanımsal filtreyle engeller.
  - **9-Noktalı `16x12` Koyu İç Disk & Turnuva Ağacı**: Yalnızca **1 adet BSRAM bloğu (`2,048` bayt)** kullanan 16-satır dairesel alt-örneklemeli tampon üzerinden 9 noktalı `16x12` iç diski paralel okur; en parlak noktayı (`max1`, glint) dışarıda bırakıp ikinci en parlak noktanın da koyu (`max2 < 108`) olmasını şart koşar. Bu sayede ince kirpikler (`4–6 px`) ve dar göz pınarı/dış köşeler **%100 elenir**.
  - **Çift Yönlü Göz Akı (Sclera) Çevresi ve Kaş Reddi**: Adayın sol/sağ (`±22/28 px`) ve alt (`+20 px`) çevresinde parlaklık artışı arar; `+26 px` altında koyu göz çukuru bulunan kaş bölgesini otomatik cezalandırarak **kaşa kaymayı %100 engeller**.
  - **1-Piksel Hassasiyetli Yerel Ağırlık Merkezi (Centroid)**: Tespit edilen 2B disk çekirdeği (`core_x, core_y`) etrafındaki `±13x10` piksellik pencerede yoğunluk ağırlıklı merkez hesabı yapar.
- **Yırtılmasız (Tear-Free) Ping-Pong Çift Tamponlu HDMI Çıkışı (`640x480 @ 60Hz`)**:
  - `24` adet BSRAM bloğu (`2 x 160x120 @ 8-bit = 38,400` bayt) kullanan ping-pong kare tamponu (`frame_buffer_bram.v`) ile kamera yazarken HDMI tamamlanmış önceki kareyi okur; yatay bölünme (tearing) tamamen engellenir.
  - Ekranda hedef ROI çerçevesi, algılanan koyu iris maskesi (kırmızı/macenta), göz bebeği sınırlayıcı kutusu ve tam boy yeşil hedef artısı (`+`) gerçek zamanlı çizilir (`osd_renderer.v`).
- **USB-UART Donanım-Döngüde Test (HIL) ve Masaüstü Canlı Monitör (`uart_hil_bridge.v`)**:
  - HDMI kablosu takılı değilken bilgisayarda `CANLI_KAMERA_AC.bat` (veya `python fpga_live_monitor.py`) çalıştırılarak kamera görüntüsü ve FPGA göz takip katmanları **~18 FPS** hızında canlı izlenebilir.
  - Bilgisayardaki test videoları (`test_videos/*.mp4`) UART üzerinden doğrudan fiziksel FPGA'ya akıtılarak donanım doğrulaması yapılabilir.

---

## Donanım Kaynak Kullanımı (`GW1NR-LV9QN88PC6/I5`)

| Kaynak | Kullanım | Toplam | Oran |
| :--- | :---: | :---: | :---: |
| **Mantık (LUT / ALU)** | `3,998` | `8,640` | `%47` |
| **Yazmaç (Register / FF)** | `1,402` | `6,693` | `%21` |
| **Blok RAM (BSRAM)** | `25` (`24` Frame Buffer + `1` Pupil Detector) | `26` | `%97` |
| **DSP (`MULTADDALU18X18`)** | `2` | `10` | `%20` |
| **PLL (`rPLL` + `CLKDIV`)** | `1` + `1` | `2` + `8` | `%50` |

---

## Klasör Yapısı

```text
├── AGENTS.md                        # Geliştirici ve AI ajan mimari/kısıt kılavuzu
├── README.md                        # Proje dokümantasyonu
├── CANLI_KAMERA_AC.bat              # PC üzerinde canlı FPGA kamera + OSD penceresini açan kısayol
├── fpga_live_monitor.py             # USB-UART (COM7) üzerinden ~18 FPS canlı masaüstü izleme arayüzü
├── tools/
│   ├── hil_verify_and_capture.py    # Win32 yerel seri port, HIL kare enjeksiyonu ve OSD çizici
│   └── sim_eye_tracker.py           # Bit-doğru (bit-accurate) v9 göz takip simülatörü
├── fpga/
│   ├── build.tcl                    # Gowin komut satırı sentezleme ve PnR betiği
│   ├── eye_tracker_9k.gprj          # Gowin EDA proje dosyası
│   └── src/
│       ├── top.v                    # Üst seviye (Top) modül
│       ├── tang_nano_9k.cst         # Fiziksel pin ve voltaj kısıtları
│       ├── tang_nano_9k.sdc         # Saat zamanlama kısıtları
│       ├── core/
│       │   ├── clock_pll.v          # 27 MHz -> 126 MHz TMDS & 25.2 MHz piksel saati (rPLL)
│       │   ├── debounce.v           # Buton ark önleyici
│       │   ├── system_fsm.v         # Sistem durum makinesi
│       │   └── uart_hil_bridge.v    # 921600 baud HIL video enjeksiyonu ve Turbo kare yakalayıcı
│       ├── camera/
│       │   ├── sccb_master.v        # 100 kHz 3-fazlı SCCB yazma sürücüsü
│       │   ├── ov7670_init_rom.v    # QVGA YUV422, BPC/WPC, Denoise ve AEC/AGC kayıt tablosu
│       │   ├── ov7670_controller.v  # Açılışta OV7670 kayıtlarını yükleyen kontrolcü
│       │   └── dvp_capture.v        # Senkronizatör + 3-piksel medyan filtreli DVP yakalayıcı
│       ├── memory/
│       │   └── frame_buffer_bram.v  # 160x120 @ 8-bit Ping-Pong çift tamponlu BSRAM
│       ├── vision/
│       │   └── pupil_detector.v     # 2B Eşmerkezli Disk-Çevre + Glint Köprülemeli göz bebeği tespiti
│       └── video/
│           ├── vga_timing_640x480.v # 640x480 @ 60Hz zamanlama üreteci
│           ├── osd_renderer.v       # ROI, iris maskesi, yeşil hedef artısı ve durum çubuğu çizici
│           ├── tmds_encoder.v       # DVI/HDMI 8b/10b TMDS kodlayıcı
│           └── hdmi_tx.v            # OSER10 5:1 DDR diferansiyel HDMI verici
└── test_videos/                     # Test videoları ve işlenmiş FPGA-OSD çıktı videoları
```

---

## Pin Bağlantı Tablosu (Tang Nano 9K <-> OV7670)

| OV7670 Pini | Tang Nano 9K Pini | Seviye | Açıklama |
| :--- | :---: | :---: | :--- |
| `3V3` / `GND` | `3V3` / `GND` | `3.3V` | Kamera beslemesi |
| `SIOC` (SCL) | Pin `25` | `LVCMOS33` | SCCB saat hattı |
| `SIOD` (SDA) | Pin `26` | `LVCMOS33` | SCCB veri hattı |
| `VSYNC` | Pin `27` | `LVCMOS33` | Dikey senkronizasyon |
| `HREF` | Pin `28` | `LVCMOS33` | Yatay aktif satır |
| `PCLK` | Pin `35` | `LVCMOS33` | Piksel saati girişi |
| `XCLK` | Pin `30` | `LVCMOS33` | FPGA'dan kameraya `12.6 MHz` saat çıkışı |
| `RESET` | Pin `48` | `LVCMOS33` | Kamera sıfırlama (`1` = Normal) |
| `PWDN` | Pin `49` | `LVCMOS33` | Güç kesme (`0` = Aktif) |
| `D7..D4` | Pin `31, 32, 33, 34` | `LVCMOS33` | Paralel veri üst 4 bit |
| `D3..D1` | Pin `40, 41, 42` | `LVCMOS33` | Paralel veri bit `3..1` |
| `D0` | Pin `51` | `LVCMOS33` | Paralel veri bit `0` |

---

## Derleme, Yükleme ve Test Komutları

### 1. Sentezleme ve Bitstream Üretimi
```powershell
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" fpga/build.tcl
```

### 2. Tang Nano 9K'ya Yükleme (Kalıcı Flash veya SRAM)
```powershell
# Kalıcı Gömülü Flash'a (embFlash) yazma:
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 5 --fsFile "C:\Users\Mert\Desktop\robotkol\fpga\impl\pnr\eye_tracker_9k.fs"

# Hızlı SRAM'e yükleme:
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile "C:\Users\Mert\Desktop\robotkol\fpga\impl\pnr\eye_tracker_9k.fs"
```

### 3. Bilgisayardan Canlı Kamera & Göz Takibi İzleme (HDMI Takılı Değilken)
`CANLI_KAMERA_AC.bat` dosyasına çift tıklayın veya terminalden çalıştırın:
```powershell
python fpga_live_monitor.py
```

---

## Yol Haritası
- [x] **Adım (a):** Tang Nano 9K LED, buton ark önleyici (debounce) ve durum makinesi doğrulaması
- [x] **Adım (b):** OV7670 kameradan görüntü alma (`12.6 MHz` XCLK, SCCB başlatma, medyan filtreli DVP yakalama)
- [x] **Adım (c):** Görüntüyü `640x480 @ 60Hz` HDMI ile yırtılmasız (ping-pong BSRAM) monitörde gösterme
- [x] **Adım (d):** Gerçek zamanlı göz bebeği tespiti (`v9` 2B Eşmerkezli Disk-Çevre + Glint köprüleme + USB-UART HIL ve Canlı PC Monitörü)
- [ ] **Adım (e):** 5-noktalı kalibrasyon ve sabit nokta (fixed-point) katsayı hesabı
- [ ] **Adım (f):** Bakış noktasını ekranda canlı gösterme ve robot kol kontrolü
