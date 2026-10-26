# AGENTS.md — Geliştirici ve Otonom Ajan Kılavuzu

Bu belge, **Tang Nano 9K FPGA Tabanlı Gerçek Zamanlı Göz Bebeği Takip Sistemi** üzerinde çalışan yapay zeka ajanları ve geliştiriciler için donanım kısıtlarını, mimari kuralları, derleme/yükleme komutlarını ve doğrulama iş akışlarını tanımlar.

---

## 1. Donanım Hedefi ve Araç Zinciri (Toolchain)

- **FPGA Kartı**: Sipeed Tang Nano 9K
- **FPGA Çipi**: Gowin `GW1NR-LV9QN88PC6/I5` (`GW1NR-9C`, Cihaz Kodu: `gw1nr9c-004`)
- **Kamera**: OV7670 (FIFO'suz, 18-pin DVP paralel arayüz + SCCB/I2C kontrol, `320x240` QVGA YUV422, yalnızca 8-bit `Y` parlaklık kanalı)
- **Video Çıkışı**: HDMI (`640x480 @ 60Hz`, `25.2 MHz` piksel saati, `126.0 MHz` 5x DDR TMDS saati, `OSER10` serileştirici)
- **USB-UART Köprüsü**: Kart üstü BL702 (`COM7`, `921600` baud, 8N1 — FPGA Pin `17` = `uart_tx`, Pin `18` = `uart_rx`)
- **Sentezleme ve PnR Aracı**:
  ```powershell
  & "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" fpga/build.tcl
  ```
- **FPGA Programlama Aracı (`programmer_cli.exe`)**:
  - **Hızlı SRAM Programlama (Geçici Test)**:
    ```powershell
    & "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile "C:\Users\Mert\Desktop\robotkol\fpga\impl\pnr\eye_tracker_9k.fs"
    ```
  - **Kalıcı Gömülü Flash (`embFlash`) Programlama**:
    ```powershell
    & "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 5 --fsFile "C:\Users\Mert\Desktop\robotkol\fpga\impl\pnr\eye_tracker_9k.fs"
    ```

---

## 2. Kritik Donanım Kısıtları ve Kurallar

1. **BSRAM (Blok RAM) Limiti (`25 / 26` Blok Dolu)**:
   - `GW1NR-9C` çipinde toplam **26 adet BSRAM** bloğu (her biri `2,048` bayt = `16 Kbit`) bulunur.
   - `u_frame_buffer` (`fpga/src/memory/frame_buffer_bram.v`): Yırtılmasız (tear-free) ping-pong çift tampon (`2 x 160x120 @ 8-bit = 38,400` bayt) için **24 BSRAM** kullanır.
   - `u_pupil_detector` (`fpga/src/vision/pupil_detector.v`): `16-satır x 128-sütun @ 8-bit` (`2,048` bayt) dairesel alt-örneklemeli 2B şablon tamponu için **1 BSRAM** kullanır.
   - **Kural**: Mevcut tasarımda boşta yalnızca **1 adet BSRAM bloğu** vardır. Yeni eklenecek modüller (kalibrasyon, bakış haritalama, robot kol kontrolü vb.) BSRAM tüketmemeli veya en fazla 1 BSRAM kullanmalıdır.

2. **Banka Voltaj Uyumluluğu (`LVCMOS33` vs `LVCMOS18`)**:
   - **Bank 1 ve Bank 2 (`3.3V`)**: `clk_27m` (Pin 52), OV7670 kamera pinleri, `uart_tx` (Pin 17), `uart_rx` (Pin 18) ve HDMI TMDS pinleri (`68..75`) `LVCMOS33` / `LVCMOS33D` standardındadır.
   - **Bank 3 (`1.8V`)**: Kart üstü butonlar (`btn_s1_n` Pin 3, `btn_s2_n` Pin 4) ve 6 adet aktif-düşük LED (`led[5:0]` Pin 10, 11, 13, 14, 15, 16) Bank 3'tedir ve **kesinlikle `IO_TYPE=LVCMOS18`** olarak tanımlanmalıdır. Bank 3 pinlerine `LVCMOS33` atanması PnR hatasına yol açar.

3. **Kamera Sinyal Bütünlüğü (DVP Senkronizasyon + Medyan Filtre)**:
   - OV7670 kameradan gelen `cam_pclk`, `cam_vsync`, `cam_href` ve `cam_data[7:0]` sinyalleri 10 cm jumper kablolardan geçtiği için `dvp_capture.v` içindeki `25.2 MHz` (`clk_pix`) çift kademeli senkronizatör, `pclk` darbe filtresi ve 3-pikselli yatay medyan filtresi (`y_median`) kesinlikle korunmalıdır.
   - Kamera yatay ayna modunda (`x_mirrored = 319 - x_cnt`) çalışır; bu nedenle bir satırdaki pikseller `pixel_x = 319`'dan `0`'a doğru azalarak akar.

---

## 3. Göz Bebeği Tespit Mimarisi (`pupil_detector.v` - `v9`)

`fpga/src/vision/pupil_detector.v` modülü tek geçişli (single-pass streaming) çalışır ve kaş, kirpik, göz pınarı/dış köşe ve kornea yansıması (glint) kaynaklı hataları aşağıdaki 4 katmanla engeller:

1. **Yatay Glint (Yansıma) Köprüleme Filtresi**:
   - 3-noktalı parlak darbe bastırma (`glint_b1`) + 2-noktalı yatay minimum (`glint_b2`) filtresi, göz bebeği içindeki 1–2 piksellik parlak kornea yansımalarını koyu irisi delmeden köprüler.
2. **9-Noktalı `16x12` Koyu İç Disk (`max1` Atmalı Turnuva Ağacı)**:
   - `16-satır x 128-sütun` dairesel BSRAM tamponu üzerinden her `(sx, sy)` aday merkezinde `16x12` piksellik eliptik disk üzerindeki 9 noktayı (`(0,0), (0,-6), (0,+6), (-8,0), (+8,0), (-6,-6), (+6,-6), (-6,+6), (+6,+6)`) paralel okur.
   - Turnuva karşılaştırıcı ağacı ile en parlak nokta (`max1`, olası glint) toplamdan çıkarılır (`c_disc = (sum9 - max1) >> 3`) ve ikinci en parlak noktanın da koyu olması (`max2 < 108`, `max2 - c0 <= 40`) şart koşulur. İnce kirpikler (`4–6 px`) ve dar göz köşeleri `16x12` diski dolduramadığı için elenir.
3. **Doyurulmuş Çift Yönlü Göz Akı (Sclera) Çevresi ve Kaş Reddi**:
   - Adayın sol/sağ (`±22 px` ve `±28 px`) ve alt (`+20 px`) çevresinde parlaklık artışı (`diff_min_lr >= 7`, `diff_max_lr >= 15`, `diff_b_out >= 7`) aranır.
   - Çevre kontrast bonusları doyurularak (`<= 32, 48, 36`) güneşli/parlak cilt kenarlarının simsiyah irisi geçmesi önlenir.
   - Adayın `+26 px` altında koyu göz çukuru varsa (`below_far < c_disc + 16`), aday **kaş (eyebrow)** olarak işaretlenip cezalandırılır.
4. **Yerel Pencere (`±13x10 px`) Yoğunluk Ağırlıklı Merkez (Centroid)**:
   - Tespit edilen 2B çekirdek (`core_x, core_y`) etrafındaki `±13x10` piksellik yerel pencerede eşik altı piksellerin karanlık ağırlıklı ortalaması alınarak 1-piksel hassasiyetli `(pupil_x, pupil_y)` merkezi üretilir.

---

## 4. USB-UART HIL Köprüsü ve Canlı İzleme Protokolü (`uart_hil_bridge.v`)

HDMI monitör bağlı olmadığında dahi FPGA'yı bilgisayardan test etmek ve canlı izlemek için `fpga/src/core/uart_hil_bridge.v` (`COM7`, `921600` baud) kullanılır:

- **`0x54` (`'T'`)**: 8 baytlık canlı telemetri paketi döner:
  `[0xAA, 0x55, status, pupil_x[7:0], pupil_y[7:0], core_x[7:0], core_y[7:0], active_thresh]`
- **`0xC5`**: Tam çözünürlüklü kare yakalama (`8` bayt telemetri + `160x120 = 19,200` bayt gri görüntü = `19,208` bayt).
- **`0xC6`**: **Turbo Canlı Akış Modu** (`8` bayt telemetri + `80x60 = 4,800` bayt görüntü = `4,808` bayt, **~18 FPS**).
- **`0x5A, 0xA5` + `40,960` bayt**: Bilgisayardan gönderilen `256x160` (`X: 287..32`, `Y: 64..223`) test videosu karesini doğrudan fiziksel FPGA içindeki `pupil_detector` ve `frame_buffer_bram` modüllerine akıtır ve 8 baytlık donanım sonucunu geri döndürür.
- **`0x00`**: HIL modundan çıkıp canlı OV7670 kamera akışına döner.

> **Önemli Not**: HDMI monitörde tam 60 Hz akıcı önizleme alırken `fpga_live_monitor.py` penceresi kapatılmalıdır; aksi halde `0xC6`/`0xC5` kare okuma istekleri sırasında `dump_active` sinyali BSRAM okuma portunu kısa süreliğine UART'a devreder.
