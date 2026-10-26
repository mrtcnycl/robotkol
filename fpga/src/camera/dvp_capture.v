// =============================================================================
// Modül: dvp_capture
// Açıklama: OV7670 DVP paralel arayüzünden (PCLK, VSYNC, HREF, D[7:0])
//           QVGA (320x240) YUV422 akışındaki 8-bit Y (parlaklık/gri tonlama)
//           kanalını yakalar.
//
// İyileştirmeler:
//   - Jumper kablolardaki yansıma/çapraz karışma (ringing/crosstalk) etkisini
//     yok etmek için PCLK, VSYNC, HREF ve D[7:0] sinyallerini 25.2 MHz (clk_pix)
//     saat alanında çift kademeli senkronizatör ve darbe filtresiyle örnekler.
//   - 3-pikselli yatay medyan filtresi (median3) ile tekil siyah ve beyaz nokta
//     gürültülerini (salt-and-pepper noise) hem ekrandan hem göz takip
//     algoritmasından tamamen temizler.
// =============================================================================
`default_nettype none

module dvp_capture (
    input  wire        clk,          // 25.2 MHz temiz sistem/piksel saati
    input  wire        rst_n,        // Aktif-düşük reset
    input  wire        cam_pclk,     // OV7670 piksel saati (~3.15 MHz)
    input  wire        cam_vsync,    // OV7670 VSYNC (Aktif yüksek: 1 = kare başı)
    input  wire        cam_href,     // OV7670 HREF (Aktif yüksek: 1 = aktif satır)
    input  wire [7:0]  cam_data,     // OV7670 D[7:0] paralel veri

    // Tam çözünürlüklü (320x240) filtrelenmiş akış çıkışları (Göz bebeği tespiti için)
    output reg         pixel_valid,
    output reg  [8:0]  pixel_x,      // 0..319
    output reg  [7:0]  pixel_y,      // 0..239
    output reg  [7:0]  pixel_y8,     // Medyan filtreden geçmiş 8-bit gri tonlama
    output reg         frame_start,  // Yeni kare başladı (1 çevrim darbe)
    output reg         frame_done,   // Kare bitti (1 çevrim darbe)

    // 160x120 @ 8-bit BSRAM Kare Tamponu Yazma Arayüzü
    output reg         fb_we,
    output reg  [14:0] fb_addr,      // 0..19199 (y_sub * 160 + x_sub)
    output reg  [7:0]  fb_wdata,

    // Tanılama (LED testi için)
    output reg  [7:0]  avg_luma,     // Son karenin ortalama parlaklığı (0..255)
    output reg         vsync_toggle, // Her 15 karede bir yön değiştiren sinyal
    output reg         pclk_toggle   // PCLK aktivite göstergesi
);

    // 1. 2-Kademeli Giriş Senkronizatörü ve PCLK Glitch Filtresi
    reg       pclk_s0,  pclk_s1,  pclk_s2;
    reg       vsync_s0, vsync_s1, vsync_d;
    reg       href_s0,  href_s1,  href_d;
    reg [7:0] data_s0,  data_s1;
    reg       pclk_clean;
    reg       pclk_clean_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pclk_s0      <= 1'b0; pclk_s1  <= 1'b0; pclk_s2 <= 1'b0;
            vsync_s0     <= 1'b0; vsync_s1 <= 1'b0; vsync_d <= 1'b0;
            href_s0      <= 1'b0; href_s1  <= 1'b0; href_d  <= 1'b0;
            data_s0      <= 8'd0; data_s1  <= 8'd0;
            pclk_clean   <= 1'b0;
            pclk_clean_d <= 1'b0;
        end else begin
            pclk_s0  <= cam_pclk;  pclk_s1  <= pclk_s0;  pclk_s2 <= pclk_s1;
            vsync_s0 <= cam_vsync; vsync_s1 <= vsync_s0; vsync_d <= vsync_s1;
            href_s0  <= cam_href;  href_s1  <= href_s0;  href_d  <= href_s1;
            data_s0  <= cam_data;  data_s1  <= data_s0;

            // PCLK ardışık 2 örnek boyunca aynı seviyede ise kabul et (Ringing/Spike reddi)
            if (pclk_s1 == pclk_s2) begin
                pclk_clean <= pclk_s1;
            end
            pclk_clean_d <= pclk_clean;
        end
    end

    wire pclk_rising   = (pclk_clean && !pclk_clean_d);
    wire vsync_rising  = (vsync_s1 && !vsync_d);
    wire vsync_falling = (!vsync_s1 && vsync_d);
    wire href_falling  = (!href_s1 && href_d);

    // 2. 3-Pikselli Yatay Medyan Filtresi (Tekil Siyah/Beyaz Noktaları Silici)
    reg [7:0] tap0;
    reg [7:0] tap1;
    wire [7:0] tap2 = data_s1;

    // tap0, tap1, tap2 ortancasını (median) bul
    wire [7:0] max_01 = (tap0 > tap1) ? tap0 : tap1;
    wire [7:0] min_01 = (tap0 > tap1) ? tap1 : tap0;
    wire [7:0] min_max01_2 = (max_01 > tap2) ? tap2 : max_01;
    wire [7:0] y_median = (min_01 > min_max01_2) ? min_01 : min_max01_2;

    // 3. Satır/Piksel Sayaçları ve Yakalama Mantığı
    reg        byte_phase;   // 0 = Y baytı, 1 = U/V baytı
    reg [8:0]  x_cnt;        // Aktif satırdaki piksel sayacı (0..319)
    reg [7:0]  y_cnt;        // Aktif karedeki satır sayacı (0..239)
    reg [4:0]  frame_div;
    reg [23:0] luma_acc;
    reg [19:0] pclk_div;

    // Yatay Ayna Modu (Selfie / Ayna görünümü: Sağa bakınca ekranda sağa gider)
    wire [8:0]  x_mirrored = 9'd319 - x_cnt;
    wire [6:0]  y_sub = y_cnt[7:1];
    wire [7:0]  x_sub = x_mirrored[8:1];
    wire [14:0] next_fb_addr = ({y_sub, 7'd0} + {2'd0, y_sub, 5'd0}) + {7'd0, x_sub};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_phase   <= 1'b0;
            x_cnt        <= 9'd0;
            y_cnt        <= 8'd0;
            tap0         <= 8'd128;
            tap1         <= 8'd128;
            pixel_valid  <= 1'b0;
            pixel_x      <= 9'd0;
            pixel_y      <= 8'd0;
            pixel_y8     <= 8'd0;
            frame_start  <= 1'b0;
            frame_done   <= 1'b0;
            fb_we        <= 1'b0;
            fb_addr      <= 15'd0;
            fb_wdata     <= 8'd0;
            avg_luma     <= 8'd0;
            vsync_toggle <= 1'b0;
            pclk_toggle  <= 1'b0;
            frame_div    <= 5'd0;
            luma_acc     <= 24'd0;
            pclk_div     <= 20'd0;
        end else begin
            pixel_valid <= 1'b0;
            frame_start <= 1'b0;
            frame_done  <= 1'b0;
            fb_we       <= 1'b0;

            if (pclk_rising) begin
                if (pclk_div >= 20'd1_000_000) begin
                    pclk_div    <= 20'd0;
                    pclk_toggle <= ~pclk_toggle;
                end else begin
                    pclk_div <= pclk_div + 20'd1;
                end
            end

            if (vsync_rising) begin
                frame_done <= 1'b1;
                avg_luma   <= luma_acc[23:16];
                if (frame_div >= 5'd14) begin
                    frame_div    <= 5'd0;
                    vsync_toggle <= ~vsync_toggle;
                end else begin
                    frame_div <= frame_div + 5'd1;
                end
            end else if (vsync_falling) begin
                frame_start <= 1'b1;
                y_cnt       <= 8'd0;
                x_cnt       <= 9'd0;
                byte_phase  <= 1'b0;
                luma_acc    <= 24'd0;
            end else if (!vsync_s1) begin
                if (href_s1) begin
                    if (pclk_rising) begin
                        byte_phase <= ~byte_phase;
                        if (byte_phase == 1'b0) begin
                            // 3-pikselli medyan penceresini kaydır
                            tap0 <= tap1;
                            tap1 <= (x_cnt == 9'd0) ? data_s1 : data_s1;
                            if (x_cnt == 9'd0) begin
                                tap0 <= data_s1;
                            end

                            if (x_cnt < 9'd320 && y_cnt < 8'd240) begin
                                pixel_valid <= 1'b1;
                                pixel_x     <= x_mirrored;
                                pixel_y     <= y_cnt;
                                pixel_y8    <= (x_cnt < 9'd2) ? data_s1 : y_median;
                                luma_acc    <= luma_acc + {16'd0, y_median};

                                if (x_cnt[0] == 1'b0 && y_cnt[0] == 1'b0) begin
                                    fb_we    <= 1'b1;
                                    fb_addr  <= next_fb_addr;
                                    fb_wdata <= (x_cnt < 9'd2) ? data_s1 : y_median;
                                end
                            end
                        end else begin
                            if (x_cnt < 9'd511) begin
                                x_cnt <= x_cnt + 9'd1;
                            end
                        end
                    end
                end else begin
                    byte_phase <= 1'b0;
                    x_cnt      <= 9'd0;
                    if (href_falling && y_cnt < 8'd255) begin
                        y_cnt <= y_cnt + 8'd1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
