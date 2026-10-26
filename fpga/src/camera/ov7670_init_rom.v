// =============================================================================
// Modül: ov7670_init_rom
// Açıklama: OV7670 kamerayı QVGA (320x240) YUV422 moduna ayarlayan, ölü/sıcak
//           piksel düzeltme (BPC/WPC), gürültü azaltma (denoise) ve yakın
//           mesafe göz çekimi için gölge aydınlatma (AGC/AEC/Gamma) tablosu.
// =============================================================================
`default_nettype none

module ov7670_init_rom (
    input  wire [6:0]  index,
    output reg  [15:0] reg_pair
);

    always @(*) begin
        case (index)
            // 1. Yazılımsal Reset ve Bekleme
            7'd0:  reg_pair = 16'h12_80; // COM7: Tüm register'ları sıfırla
            7'd1:  reg_pair = 16'hFF_00; // Özel komut: Reset sonrası ~10 ms bekle

            // 2. Saat ve Çıkış Formatı (YUV422, Y-kanalı ilk bayt)
            7'd2:  reg_pair = 16'h12_00; // COM7: YUV çıkış modu
            7'd3:  reg_pair = 16'h11_00; // CLKRC: Harici XCLK'yı doğrudan kullan
            7'd4:  reg_pair = 16'h6B_0A; // DBLV: PLL bypass (10 cm jumper kabloda kararlı saat)
            7'd5:  reg_pair = 16'h3A_04; // TSLB: YUYV dizilimi (Çift indeksli baytlar = Y parlaklık)
            7'd6:  reg_pair = 16'h3D_C0; // COM13: Gamma etkin, UV otomatik

            // 3. QVGA (320x240) Donanımsal Ölçekleme (DCW & Scaling)
            7'd7:  reg_pair = 16'h0C_04; // COM3: DCW (Downsample) etkinleştir
            7'd8:  reg_pair = 16'h3E_19; // COM14: Manuel ölçekleme ve PCLK /2 bölücü etkin
            7'd9:  reg_pair = 16'h70_3A; // SCALING_XSC: Yatay ölçekleme faktörü
            7'd10: reg_pair = 16'h71_35; // SCALING_YSC: Dikey ölçekleme faktörü
            7'd11: reg_pair = 16'h72_11; // SCALING_DCWCTR: Yatay ve dikey 2x alt-örnekleme
            7'd12: reg_pair = 16'h73_F1; // SCALING_PCLK_DIV: DSP PCLK bölücü = /2
            7'd13: reg_pair = 16'hA2_02; // SCALING_PCLK_DELAY: Ölçekleme gecikmesi

            // 4. Pencereleme Zamanlaması (HSTART/HSTOP/VSTART/VSTOP)
            7'd14: reg_pair = 16'h17_16; // HSTART
            7'd15: reg_pair = 16'h18_04; // HSTOP
            7'd16: reg_pair = 16'h32_A4; // HREF
            7'd17: reg_pair = 16'h19_02; // VSTART
            7'd18: reg_pair = 16'h1A_7A; // VSTOP
            7'd19: reg_pair = 16'h03_0A; // VREF

            // 5. Senkronizasyon ve Siyah/Beyaz Nokta Gürültü Filtreleri (BPC/WPC)
            7'd20: reg_pair = 16'h15_20; // COM10: Yatay boşlukta (HREF=0) PCLK geçişlerini sustur
            7'd21: reg_pair = 16'h1E_07; // MVFP: Görüntü yönü normal
            7'd22: reg_pair = 16'h41_38; // COM16: Denoise (gürültü silme) ve kenar iyileştirme etkin
            7'd23: reg_pair = 16'h76_E1; // Siyah/Beyaz nokta düzeltme (BPC + WPC) donanımsal filtre etkin
            7'd24: reg_pair = 16'h77_04; // De-noise ofseti

            // 6. Yakın Göz Çekimi İçin Dengeli Pozlama (AEC), Kazanç (AGC) ve Parlaklık
            7'd25: reg_pair = 16'h13_E7; // COM8: Hızlı AEC, AGC ve AWB etkin
            7'd26: reg_pair = 16'h14_28; // COM9: Maksimum AGC kazancı 8x
            7'd27: reg_pair = 16'h24_75; // AEW: Otomatik pozlama üst sınırı
            7'd28: reg_pair = 16'h25_63; // AEB: Otomatik pozlama alt sınırı
            7'd29: reg_pair = 16'h26_A5; // VPT: Hızlı yakınsama kontrol penceresi
            7'd30: reg_pair = 16'h55_06; // BRIGHT: Hafif parlaklık (+6)
            7'd31: reg_pair = 16'h56_44; // CONTRAS: Dengeli kontrast
            7'd32: reg_pair = 16'h3B_0A; // COM11: 50Hz titreme (banding) filtresi

            default: reg_pair = 16'hFF_FF; // Tablo sonu
        endcase
    end

endmodule

`default_nettype wire
