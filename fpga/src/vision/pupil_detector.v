// =============================================================================
// Modül: pupil_detector (v9 - 2B Eşmerkezli Disk-Çevre + Glint Köprülemeli)
// Açıklama: 320x240 @ 8-bit gri tonlama akışı üzerinde:
//           1. Yatay Glint Köprüleme Filtresi:
//              Göz bebeği içindeki parlak ışık yansımasının (glint) koyu diski
//              delmesini önler.
//           2. 16-Satır x 128-Sütun (1 BSRAM Bloğu) Dairesel Alt-Örneklemeli Tampon:
//              Her (sx, sy) aday merkezi için gerçek zamanlı 2B şablon okur:
//                - İç Koyu Disk (16x12 piksel, 9 nokta): En parlak 1 noktayı (glint)
//                  dışarıda bırakarak kalan 8 noktanın ortalamasını (c_disc) ve
//                  ikinci en parlak noktayı (max2) hesaplar. İnce kirpikler ve
//                  dar göz köşeleri 16x12 diski dolduramadığı için %100 elenir!
//                - Yatay Göz Akı (Sclera) Çevresi (+/-22 ve +/-28 piksel):
//                  Her iki yanda parlaklık artışı şartı ile geniş kaş (eyebrow)
//                  bantlarını %100 reddeder; doyurulmuş (saturated) kontrast
//                  puanı sayesinde parlak şakak/göz pınarı kenarlarının siyah
//                  irisi geçmesini engeller.
//                - Alt Yanak/Göz Akı (+20px) ve Kaş-Altı Göz (+26px) Doğrulaması:
//                  Kaşın 26 piksel altında koyu göz çukuru bulunduğundan kaş
//                  bölgesini cezalandırır, irisin 20 piksel altındaki aydınlık
//                  alt göz kapağını ödüllendirir.
//           3. Yerel Pencere (+/-13x10 piksel) Yoğunluk Ağırlıklı Merkez (Centroid):
//              Tespit edilen 2B disk çekirdeği etrafında 1-piksel hassasiyetli
//              ağırlık merkezi hesaplar.
// =============================================================================
`default_nettype none

module pupil_detector #(
    parameter [8:0] ROI_X_MIN    = 9'd90,   // 140 piksel genişlik (merkez 160)
    parameter [8:0] ROI_X_MAX    = 9'd230,
    parameter [7:0] ROI_Y_MIN    = 8'd104,  // 80 piksel yükseklik (merkez 144)
    parameter [7:0] ROI_Y_MAX    = 8'd184,
    parameter [7:0] GLINT_THRESH = 8'd230
) (
    input  wire       clk,
    input  wire       rst_n,

    // dvp_capture veya uart_hil_bridge'den gelen 320x240 piksel akışı
    input  wire       pixel_valid,
    input  wire [8:0] pixel_x,      // 0..319 (dvp_capture'da 319 -> 0 azalır)
    input  wire [7:0] pixel_y,      // 0..239
    input  wire [7:0] pixel_y8,
    input  wire       frame_start,
    input  wire       frame_done,

    // Tespit edilen Göz Bebeği (Pupil) Koordinatları ve Çekirdek Penceresi
    output reg        pupil_valid,
    output reg  [8:0] pupil_x,      // 0..319
    output reg  [7:0] pupil_y,      // 0..239
    output reg  [7:0] active_thresh,
    output reg  [8:0] core_x,       // 2B Disk Çekirdek X
    output reg  [7:0] core_y,       // 2B Disk Çekirdek Y

    // Tespit edilen Glint (Kornea Yansıması) Koordinatları
    output reg        glint_valid,
    output reg  [8:0] glint_x,
    output reg  [7:0] glint_y
);

    // -------------------------------------------------------------------------
    // 1. Yatay Glint Köprüleme Filtresi (1-2 Piksellik Kornea Yansımasını Siler)
    // -------------------------------------------------------------------------
    reg [7:0] raw_d0, raw_d1, raw_d2;
    wire [7:0] max_nb   = (raw_d0 > raw_d2) ? raw_d0 : raw_d2;
    wire [7:0] glint_b1 = (raw_d1 < max_nb) ? raw_d1 : max_nb;

    reg [7:0] gb1_d1, gb1_d2;
    wire [7:0] glint_b2 = (glint_b1 < gb1_d2) ? glint_b1 : gb1_d2;

    reg [7:0] gb2_d1;
    wire [8:0] pair_sum     = {1'b0, glint_b2} + {1'b0, gb2_d1};
    wire [7:0] sub_pair_avg = pair_sum[8:1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_d0 <= 8'd128; raw_d1 <= 8'd128; raw_d2 <= 8'd128;
            gb1_d1 <= 8'd128; gb1_d2 <= 8'd128;
            gb2_d1 <= 8'd128;
        end else if (pixel_valid) begin
            raw_d0 <= pixel_y8;
            raw_d1 <= raw_d0;
            raw_d2 <= raw_d1;
            gb1_d1 <= glint_b1;
            gb1_d2 <= gb1_d1;
            gb2_d1 <= glint_b2;
        end
    end

    // -------------------------------------------------------------------------
    // 2. 16-Satır x 128-Sütun Dairesel BSRAM Tamponu (2048 x 8-bit = 1 BSRAM)
    //    Kapsanan Alan: X = 32..287 (128 alt-sütun), Y = 64..223
    // -------------------------------------------------------------------------
    reg [7:0] line_buf [0:2047];
    reg [7:0] bsram_dout;

    reg        bsram_we;
    reg [10:0] bsram_waddr;
    reg [7:0]  bsram_wdata;
    reg [10:0] bsram_raddr;

    always @(posedge clk) begin
        if (bsram_we) begin
            line_buf[bsram_waddr] <= bsram_wdata;
        end
        bsram_dout <= line_buf[bsram_raddr];
    end

    wire in_buf_x = (pixel_x >= 9'd32) && (pixel_x < 9'd288);
    wire in_buf_y = (pixel_y >= 8'd64) && (pixel_y < 8'd224);
    wire sub_trig = pixel_valid && in_buf_x && in_buf_y && (pixel_y[0] == 1'b1) && (pixel_x[0] == 1'b0);

    wire [8:0] x_off  = pixel_x - 9'd32;
    wire [6:0] c_curr = x_off[7:1];
    wire [3:0] r_curr = pixel_y[4:1];

    reg [2:0] bsram_state;
    reg [3:0] sav_r;
    reg [6:0] sav_c;
    reg [7:0] sav_val;
    reg [8:0] sav_px;
    reg [7:0] sav_py;
    reg [6:0] line_col_cnt;

    reg [7:0] rd_top;
    reg [7:0] rd_mid;
    reg [7:0] rd_bot;

    wire [3:0] r_m13 = sav_r - 4'd13;
    wire [3:0] r_m10 = sav_r - 4'd10;
    wire [3:0] r_m3  = sav_r - 4'd3;
    wire [6:0] c_p14 = sav_c + 7'd14;

    always @(*) begin
        bsram_we    = 1'b0;
        bsram_waddr = {sav_r, sav_c};
        bsram_wdata = sav_val;
        bsram_raddr = {sav_r, sav_c};

        case (bsram_state)
            3'd0: begin
                bsram_raddr = {r_curr, c_curr}; // Okuma #1: r_curr - 16 (sy - 3)
            end
            3'd1: begin
                bsram_raddr = {r_m13, sav_c};   // Okuma #2: r_curr - 13 (sy)
            end
            3'd2: begin
                bsram_raddr = {r_m10, sav_c};   // Okuma #3: r_curr - 10 (sy + 3)
            end
            3'd3: begin
                bsram_raddr = {r_m3, c_p14};    // Okuma #4: r_curr - 3  (sy + 10 @ X_center)
                bsram_we    = 1'b1;             // Yazma   : r_curr      (sy + 13 @ sav_c)
            end
            default: begin
                bsram_raddr = {sav_r, sav_c};
            end
        endcase
    end

    // Yatay kaydırma yazmaçları (Shift Registers)
    reg [7:0] sr_top [0:17];
    reg [7:0] sr_mid [0:28];
    reg [7:0] sr_bot [0:17];
    reg [7:0] sr_b13 [0:14];
    reg [7:0] lat_b10;

    reg       pipe1_valid;
    reg [8:0] pipe1_px;
    reg [7:0] pipe1_py;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bsram_state  <= 3'd0;
            sav_r        <= 4'd0;
            sav_c        <= 7'd0;
            sav_val      <= 8'd128;
            sav_px       <= 9'd0;
            sav_py       <= 8'd0;
            line_col_cnt <= 7'd0;
            rd_top       <= 8'd128;
            rd_mid       <= 8'd128;
            rd_bot       <= 8'd128;
            lat_b10      <= 8'd128;
            pipe1_valid  <= 1'b0;
            pipe1_px     <= 9'd160;
            pipe1_py     <= 8'd144;
            for (i = 0; i < 18; i = i + 1) begin
                sr_top[i] <= 8'd128;
                sr_bot[i] <= 8'd128;
            end
            for (i = 0; i < 29; i = i + 1) begin
                sr_mid[i] <= 8'd128;
            end
            for (i = 0; i < 15; i = i + 1) begin
                sr_b13[i] <= 8'd128;
            end
        end else begin
            pipe1_valid <= 1'b0;

            case (bsram_state)
                3'd0: begin
                    if (sub_trig) begin
                        sav_r   <= r_curr;
                        sav_c   <= c_curr;
                        sav_val <= sub_pair_avg;
                        sav_px  <= pixel_x;
                        sav_py  <= pixel_y;
                        if (pixel_y != sav_py) begin
                            line_col_cnt <= 7'd0;
                        end else if (line_col_cnt < 7'd127) begin
                            line_col_cnt <= line_col_cnt + 7'd1;
                        end
                        bsram_state <= 3'd1;
                    end
                end

                3'd1: begin
                    rd_top      <= bsram_dout;
                    bsram_state <= 3'd2;
                end

                3'd2: begin
                    rd_mid      <= bsram_dout;
                    bsram_state <= 3'd3;
                end

                3'd3: begin
                    rd_bot      <= bsram_dout;
                    bsram_state <= 3'd4;
                end

                3'd4: begin
                    lat_b10   <= bsram_dout;
                    sr_top[0] <= rd_top;
                    for (i = 1; i < 18; i = i + 1) sr_top[i] <= sr_top[i - 1];

                    sr_mid[0] <= rd_mid;
                    for (i = 1; i < 29; i = i + 1) sr_mid[i] <= sr_mid[i - 1];

                    sr_bot[0] <= rd_bot;
                    for (i = 1; i < 18; i = i + 1) sr_bot[i] <= sr_bot[i - 1];

                    sr_b13[0] <= sav_val;
                    for (i = 1; i < 15; i = i + 1) sr_b13[i] <= sr_b13[i - 1];

                    // 14 alt-sütun (28 piksel) + 3 piksel filtre gecikmesi önceki merkez koordinatı
                    pipe1_px    <= sav_px + 9'd32;
                    pipe1_py    <= sav_py - 8'd25;
                    pipe1_valid <= (line_col_cnt >= 7'd28) && (sav_py >= 8'd129) && (sav_py < 8'd209);
                    bsram_state <= 3'd0;
                end

                default: bsram_state <= 3'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 3. Boru Hattı Aşama 1 (Pipeline Stage 1):
    //    9-Noktalı 16x12 İç Diskten max1 (glint) ve max2 tespiti + Çevre Okuma
    // -------------------------------------------------------------------------
    wire [7:0] p0 = sr_mid[14]; // Merkez (0, 0)
    wire [7:0] p1 = sr_top[14]; // Üst (0, -6)
    wire [7:0] p2 = sr_bot[14]; // Alt (0, +6)
    wire [7:0] p3 = sr_mid[10]; // Sağ/Sol (-8, 0)
    wire [7:0] p4 = sr_mid[18]; // Sol/Sağ (+8, 0)
    wire [7:0] p5 = sr_top[11]; // Köşe 1 (-6, -6)
    wire [7:0] p6 = sr_top[17]; // Köşe 2 (+6, -6)
    wire [7:0] p7 = sr_bot[11]; // Köşe 3 (-6, +6)
    wire [7:0] p8 = sr_bot[17]; // Köşe 4 (+6, +6)

    // Turnuva ağacı ile 9 noktanın en büyüğü (max1) ve ikinci en büyüğü (max2)
    wire [7:0] hi12 = (p1 > p2) ? p1 : p2;
    wire [7:0] lo12 = (p1 > p2) ? p2 : p1;
    wire [7:0] hi34 = (p3 > p4) ? p3 : p4;
    wire [7:0] lo34 = (p3 > p4) ? p4 : p3;
    wire [7:0] max1_A = (hi12 > hi34) ? hi12 : hi34;
    wire [7:0] min_hiA = (hi12 > hi34) ? hi34 : hi12;
    wire [7:0] max_loA = (lo12 > lo34) ? lo12 : lo34;
    wire [7:0] max2_A = (min_hiA > max_loA) ? min_hiA : max_loA;

    wire [7:0] hi56 = (p5 > p6) ? p5 : p6;
    wire [7:0] lo56 = (p5 > p6) ? p6 : p5;
    wire [7:0] hi78 = (p7 > p8) ? p7 : p8;
    wire [7:0] lo78 = (p7 > p8) ? p8 : p7;
    wire [7:0] max1_B = (hi56 > hi78) ? hi56 : hi78;
    wire [7:0] min_hiB = (hi56 > hi78) ? hi78 : hi56;
    wire [7:0] max_loB = (lo56 > lo78) ? lo56 : lo78;
    wire [7:0] max2_B = (min_hiB > max_loB) ? min_hiB : max_loB;

    wire [7:0] max1_AB = (max1_A > max1_B) ? max1_A : max1_B;
    wire [7:0] min_hiAB = (max1_A > max1_B) ? max1_B : max1_A;
    wire [7:0] max2_AB_pre = (max2_A > max2_B) ? max2_A : max2_B;
    wire [7:0] max2_AB = (min_hiAB > max2_AB_pre) ? min_hiAB : max2_AB_pre;

    wire [7:0] max1_all = (max1_AB > p0) ? max1_AB : p0;
    wire [7:0] min_hi9  = (max1_AB > p0) ? p0 : max1_AB;
    wire [7:0] max2_all = (min_hi9 > max2_AB) ? min_hi9 : max2_AB;

    wire [11:0] sum9 = {4'd0, p0} + {4'd0, p1} + {4'd0, p2} + {4'd0, p3} +
                       {4'd0, p4} + {4'd0, p5} + {4'd0, p6} + {4'd0, p7} + {4'd0, p8};
    wire [11:0] sum8 = sum9 - {4'd0, max1_all};
    wire [7:0]  c_disc_w = sum8[10:3]; // (sum9 - max1) >> 3

    // Yatay çevre: +/-11 ve +/-14 alt-sütun (+/-22 ve +/-28 piksel)
    wire [7:0] side_A = (sr_mid[3]  > sr_mid[0])  ? sr_mid[3]  : sr_mid[0];
    wire [7:0] side_B = (sr_mid[25] > sr_mid[28]) ? sr_mid[25] : sr_mid[28];

    reg        pipe2_valid;
    reg [8:0]  pipe2_px;
    reg [7:0]  pipe2_py;
    reg [7:0]  p2_c0;
    reg [7:0]  p2_c_disc;
    reg [7:0]  p2_max2;
    reg [7:0]  p2_side_min;
    reg [7:0]  p2_side_max;
    reg [7:0]  p2_b_out;
    reg [7:0]  p2_below_far;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe2_valid  <= 1'b0;
            pipe2_px     <= 9'd160;
            pipe2_py     <= 8'd144;
            p2_c0        <= 8'd128;
            p2_c_disc    <= 8'd128;
            p2_max2      <= 8'd128;
            p2_side_min  <= 8'd128;
            p2_side_max  <= 8'd128;
            p2_b_out     <= 8'd128;
            p2_below_far <= 8'd128;
        end else begin
            pipe2_valid <= pipe1_valid &&
                           (pipe1_px >= ROI_X_MIN + 9'd8) && (pipe1_px < ROI_X_MAX - 9'd8) &&
                           (pipe1_py >= ROI_Y_MIN + 8'd10) && (pipe1_py < ROI_Y_MAX - 8'd8);
            pipe2_px     <= pipe1_px;
            pipe2_py     <= pipe1_py;
            p2_c0        <= p0;
            p2_c_disc    <= c_disc_w;
            p2_max2      <= max2_all;
            p2_side_min  <= (side_A < side_B) ? side_A : side_B;
            p2_side_max  <= (side_A > side_B) ? side_A : side_B;
            p2_b_out     <= lat_b10;
            p2_below_far <= sr_b13[14];
        end
    end

    // -------------------------------------------------------------------------
    // 4. Boru Hattı Aşama 2 (Pipeline Stage 2):
    //    2B Eşmerkezli Disk-Çevre Puanlama ve En İyi Çekirdek Seçimi
    // -------------------------------------------------------------------------
    wire signed [9:0] diff_min_lr = $signed({2'b00, p2_side_min}) - $signed({2'b00, p2_c_disc});
    wire signed [9:0] diff_max_lr = $signed({2'b00, p2_side_max}) - $signed({2'b00, p2_c_disc});
    wire signed [9:0] diff_b_out  = $signed({2'b00, p2_b_out})    - $signed({2'b00, p2_c_disc});
    wire signed [9:0] disc_spread = $signed({2'b00, p2_max2})     - $signed({2'b00, p2_c0});

    wire cand_ok = (p2_c_disc < 8'd92) &&
                   (p2_max2   < 8'd108) &&
                   (disc_spread <= 10'sd40) &&
                   (diff_min_lr >= 10'sd7) &&
                   (diff_max_lr >= 10'sd15) &&
                   (diff_b_out  >= 10'sd7);

    // Doyurulmuş (saturated) çevre kontrast bonusları
    wire [7:0] min_lr_cap = (diff_min_lr > 10'sd32) ? 8'd32 : diff_min_lr[7:0];
    wire [7:0] max_lr_cap = (diff_max_lr > 10'sd48) ? 8'd48 : diff_max_lr[7:0];
    wire [7:0] diff_b_cap = (diff_b_out  > 10'sd36) ? 8'd36 : diff_b_out[7:0];

    // Kaş cezası: Adayın 26 piksel altında koyu göz çukuru varsa (below_far < c_disc + 16)
    wire [8:0] c_plus_16    = {1'b0, p2_c_disc} + 9'd16;
    wire [8:0] brow_diff    = (c_plus_16 > {1'b0, p2_below_far}) ? (c_plus_16 - {1'b0, p2_below_far}) : 9'd0;
    wire [10:0] brow_pen    = {brow_diff, 2'b00}; // * 4

    // Üst ve yan sınır cezaları
    wire [7:0] top_diff     = (pipe2_py < 8'd118) ? (8'd118 - pipe2_py) : 8'd0;
    wire [9:0] top_pen      = ({2'b0, top_diff} << 1) + {2'b0, top_diff}; // * 3
    wire [8:0] side_pen     = ((pipe2_px < 9'd98)  ? (9'd98  - pipe2_px) : 9'd0) +
                              ((pipe2_px > 9'd222) ? (pipe2_px - 9'd222) : 9'd0);

    wire [10:0] pos_score = ({3'd0, (8'd128 - p2_c_disc)} << 2) +
                            ({3'd0, (8'd128 - p2_max2)}   << 1) +
                            ({3'd0, min_lr_cap}           << 1) +
                            {3'd0, max_lr_cap} +
                            {3'd0, diff_b_cap};

    wire [10:0] tot_pen   = brow_pen + {1'b0, top_pen} + {2'b0, side_pen};
    wire signed [11:0] cand_score = $signed({1'b0, pos_score}) - $signed({1'b0, tot_pen});

    // -------------------------------------------------------------------------
    // 5. Yerel Pencere (+/-13x10) Ağırlık Merkezi (Centroid) ve Kare Sonu Bölme
    // -------------------------------------------------------------------------
    wire in_roi = (pixel_x >= ROI_X_MIN && pixel_x < ROI_X_MAX) &&
                  (pixel_y >= ROI_Y_MIN && pixel_y < ROI_Y_MAX);

    wire [8:0] dx_core = (pixel_x >= core_x) ? (pixel_x - core_x) : (core_x - pixel_x);
    wire [7:0] dy_core = (pixel_y >= core_y) ? (pixel_y - core_y) : (core_y - pixel_y);
    wire       in_local_box = (dx_core <= 9'd13) && (dy_core <= 8'd10);

    wire [7:0] diff_dark = (active_thresh >= glint_b2) ? (active_thresh - glint_b2) : 8'd0;
    wire [4:0] weight    = (diff_dark >= 8'd15) ? 5'd16 : (diff_dark[3:0] + 5'd1);

    reg signed [11:0] frame_best_score;
    reg [8:0]         frame_best_x;
    reg [7:0]         frame_best_y;
    reg [7:0]         frame_best_c;

    reg [23:0] sum_px;
    reg [22:0] sum_py;
    reg [15:0] sum_w;

    reg [19:0] sum_gx;
    reg [18:0] sum_gy;
    reg [11:0] cnt_g;

    localparam [1:0] DIV_IDLE = 2'd0;
    localparam [1:0] DIV_RUN  = 2'd1;
    localparam [1:0] DIV_DONE = 2'd2;

    reg [1:0]  div_state;
    reg [3:0]  div_step;
    reg [24:0] rem_x;
    reg [24:0] rem_y;
    reg [15:0] denom_p;
    reg [8:0]  quot_x;
    reg [8:0]  quot_y;

    reg [20:0] rem_gx;
    reg [20:0] rem_gy;
    reg [11:0] denom_g;
    reg [8:0]  quot_gx;
    reg [8:0]  quot_gy;

    reg        next_p_valid;
    reg        next_g_valid;
    reg        use_centroid;
    reg [8:0]  lat_best_x;
    reg [7:0]  lat_best_y;

    wire [24:0] shifted_denom_p = {9'd0, denom_p} << div_step;
    wire [20:0] shifted_denom_g = {9'd0, denom_g} << div_step;

    wire [8:0] jump_dx = (frame_best_x >= core_x) ? (frame_best_x - core_x) : (core_x - frame_best_x);
    wire [7:0] jump_dy = (frame_best_y >= core_y) ? (frame_best_y - core_y) : (core_y - frame_best_y);

    wire [8:0] next_th_raw = {1'b0, frame_best_c} + 9'd16;
    wire [7:0] next_th_clamped = (next_th_raw < 9'd20)  ? 8'd20  :
                                 (next_th_raw > 9'd120) ? 8'd120 :
                                 next_th_raw[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_x           <= 9'd160;
            core_y           <= 8'd144;
            frame_best_score <= -12'sd2048;
            frame_best_x     <= 9'd160;
            frame_best_y     <= 8'd144;
            frame_best_c     <= 8'd40;
            active_thresh    <= 8'd56;
            sum_px           <= 24'd0;
            sum_py           <= 23'd0;
            sum_w            <= 16'd0;
            sum_gx           <= 20'd0;
            sum_gy           <= 19'd0;
            cnt_g            <= 12'd0;
            pupil_valid      <= 1'b0;
            pupil_x          <= 9'd160;
            pupil_y          <= 8'd144;
            glint_valid      <= 1'b0;
            glint_x          <= 9'd160;
            glint_y          <= 8'd144;
            div_state        <= DIV_IDLE;
            div_step         <= 4'd0;
            rem_x            <= 25'd0;
            rem_y            <= 25'd0;
            denom_p          <= 16'd1;
            quot_x           <= 9'd0;
            quot_y           <= 9'd0;
            rem_gx           <= 21'd0;
            rem_gy           <= 21'd0;
            denom_g          <= 12'd1;
            quot_gx          <= 9'd0;
            quot_gy          <= 9'd0;
            next_p_valid     <= 1'b0;
            next_g_valid     <= 1'b0;
            use_centroid     <= 1'b0;
            lat_best_x       <= 9'd160;
            lat_best_y       <= 8'd144;
        end else begin
            if (frame_start) begin
                frame_best_score <= -12'sd2048;
                sum_px           <= 24'd0;
                sum_py           <= 23'd0;
                sum_w            <= 16'd0;
                sum_gx           <= 20'd0;
                sum_gy           <= 19'd0;
                cnt_g            <= 12'd0;
            end else begin
                if (pipe2_valid && cand_ok && (cand_score > frame_best_score)) begin
                    frame_best_score <= cand_score;
                    frame_best_x     <= pipe2_px;
                    frame_best_y     <= pipe2_py;
                    frame_best_c     <= p2_c_disc;
                end

                if (pixel_valid && in_roi && in_local_box) begin
                    if ((glint_b2 <= active_thresh) && (sum_w < 16'd60000)) begin
                        sum_px <= sum_px + ({15'd0, pixel_x} * {19'd0, weight});
                        sum_py <= sum_py + ({15'd0, pixel_y} * {18'd0, weight});
                        sum_w  <= sum_w  + {11'd0, weight};
                    end
                    if ((pixel_y8 >= GLINT_THRESH) && (cnt_g < 12'd4000)) begin
                        sum_gx <= sum_gx + {11'd0, pixel_x};
                        sum_gy <= sum_gy + {11'd0, pixel_y};
                        cnt_g  <= cnt_g  + 12'd1;
                    end
                end
            end

            case (div_state)
                DIV_IDLE: begin
                    if (frame_done) begin
                        if (frame_best_score >= 12'sd380) begin
                            core_x        <= frame_best_x;
                            core_y        <= frame_best_y;
                            active_thresh <= next_th_clamped;
                            next_p_valid  <= 1'b1;
                        end else begin
                            next_p_valid  <= 1'b0;
                        end

                        lat_best_x   <= frame_best_x;
                        lat_best_y   <= frame_best_y;
                        use_centroid <= (jump_dx <= 9'd12) && (jump_dy <= 8'd10) && (sum_w >= 16'd20);
                        next_g_valid <= (cnt_g >= 12'd1 && cnt_g <= 12'd300);

                        rem_x        <= {1'b0, sum_px};
                        rem_y        <= {2'b0, sum_py};
                        denom_p      <= (sum_w == 16'd0) ? 16'd1 : sum_w;
                        quot_x       <= 9'd0;
                        quot_y       <= 9'd0;

                        rem_gx       <= {1'b0, sum_gx};
                        rem_gy       <= {2'b0, sum_gy};
                        denom_g      <= (cnt_g == 12'd0) ? 12'd1 : cnt_g;
                        quot_gx      <= 9'd0;
                        quot_gy      <= 9'd0;

                        div_step     <= 4'd8;
                        div_state    <= DIV_RUN;
                    end
                end

                DIV_RUN: begin
                    if (rem_x >= shifted_denom_p) begin
                        rem_x            <= rem_x - shifted_denom_p;
                        quot_x[div_step] <= 1'b1;
                    end
                    if (rem_y >= shifted_denom_p) begin
                        rem_y            <= rem_y - shifted_denom_p;
                        quot_y[div_step] <= 1'b1;
                    end
                    if (rem_gx >= shifted_denom_g) begin
                        rem_gx            <= rem_gx - shifted_denom_g;
                        quot_gx[div_step] <= 1'b1;
                    end
                    if (rem_gy >= shifted_denom_g) begin
                        rem_gy            <= rem_gy - shifted_denom_g;
                        quot_gy[div_step] <= 1'b1;
                    end

                    if (div_step == 4'd0) begin
                        div_state <= DIV_DONE;
                    end else begin
                        div_step <= div_step - 4'd1;
                    end
                end

                DIV_DONE: begin
                    pupil_valid <= next_p_valid;
                    if (next_p_valid) begin
                        if (use_centroid) begin
                            pupil_x <= ({1'b0, pupil_x} + {1'b0, quot_x}) >> 1;
                            pupil_y <= ({1'b0, pupil_y} + {1'b0, quot_y[7:0]}) >> 1;
                        end else begin
                            pupil_x <= ({1'b0, pupil_x} + {1'b0, lat_best_x}) >> 1;
                            pupil_y <= ({1'b0, pupil_y} + {1'b0, lat_best_y}) >> 1;
                        end
                    end
                    glint_valid <= next_g_valid;
                    if (next_g_valid) begin
                        glint_x <= quot_gx;
                        glint_y <= quot_gy[7:0];
                    end
                    div_state <= DIV_IDLE;
                end

                default: div_state <= DIV_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
