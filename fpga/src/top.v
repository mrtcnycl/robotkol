// =============================================================================
// Modül: top (Adım b + c + d: Gürültü Filtreli OV7670 + Göz Bebeği Tespiti + HDMI + UART HIL)
// Hedef : Tang Nano 9K (GW1NR-LV9QN88PC6/I5)
// =============================================================================
`default_nettype none

module top (
    input  wire       clk_27m,
    input  wire       btn_s1_n,
    input  wire       btn_s2_n,
    output wire [5:0] led,

    // USB-UART (BL702 Köprüsü: Pin 18 = RX, Pin 17 = TX)
    input  wire       uart_rx,
    output wire       uart_tx,

    // OV7670 Kamera Arayüzü
    output wire       cam_sioc,
    inout  wire       cam_siod,
    input  wire       cam_vsync,
    input  wire       cam_href,
    input  wire       cam_pclk,
    output wire       cam_xclk,
    output wire       cam_rst_n,
    output wire       cam_pwdn,
    input  wire [7:0] cam_data,

    // HDMI (TMDS) Çıkışı
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    wire rst_n = btn_s1_n;

    // -------------------------------------------------------------------------
    // 1. HDMI Saat Üretimi (rPLL + CLKDIV: 126.0 MHz TMDS ve 25.2 MHz Piksel)
    // -------------------------------------------------------------------------
    wire clk_tmds;
    wire clk_pix;
    wire pll_lock;
    wire video_rst_n = rst_n & pll_lock;

    clock_pll u_clock_pll (
        .clk_27m (clk_27m),
        .rst_n   (rst_n),
        .clk_tmds(clk_tmds),
        .clk_pix (clk_pix),
        .pll_lock(pll_lock)
    );

    // -------------------------------------------------------------------------
    // 2. OV7670 Sabit Kontrol Pinleri ve XCLK Üretimi (12.6 MHz = 25.2 MHz / 2)
    // -------------------------------------------------------------------------
    assign cam_rst_n = 1'b1;
    assign cam_pwdn  = 1'b0;

    reg xclk_div;
    always @(posedge clk_pix or negedge video_rst_n) begin
        if (!video_rst_n) begin
            xclk_div <= 1'b0;
        end else begin
            xclk_div <= ~xclk_div;
        end
    end
    assign cam_xclk = xclk_div; // 25.2 MHz / 2 = 12.6 MHz (Tam akıcı kare hızı)

    // -------------------------------------------------------------------------
    // 3. S2 Butonu Ark Önleyici ve Sistem Durum Makinesi
    // -------------------------------------------------------------------------
    wire s2_level;
    wire s2_pressed;

    debounce #(
        .CLK_FREQ_HZ(27_000_000),
        .DEBOUNCE_MS(20)
    ) u_debounce_s2 (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_in_n   (btn_s2_n),
        .btn_level  (s2_level),
        .btn_pressed(s2_pressed)
    );

    wire [1:0] sys_state;
    wire [2:0] calib_index;
    wire       sample_capture;

    system_fsm #(
        .NUM_CALIB_POINTS(5)
    ) u_system_fsm (
        .clk           (clk_27m),
        .rst_n         (rst_n),
        .action_pulse  (s2_pressed),
        .state         (sys_state),
        .calib_index   (calib_index),
        .sample_capture(sample_capture)
    );

    // -------------------------------------------------------------------------
    // 4. OV7670 SCCB Başlatma Kontrolcüsü
    // -------------------------------------------------------------------------
    wire cam_init_done;
    wire cam_ctrl_rst_n = rst_n & ~s2_pressed;

    ov7670_controller #(
        .CLK_FREQ_HZ(27_000_000)
    ) u_ov7670_ctrl (
        .clk      (clk_27m),
        .rst_n    (cam_ctrl_rst_n),
        .init_done(cam_init_done),
        .cam_sioc (cam_sioc),
        .cam_siod (cam_siod)
    );

    // -------------------------------------------------------------------------
    // 5. OV7670 DVP Görüntü Yakalayıcı (Senkron + Medyan Gürültü Filtreli)
    // -------------------------------------------------------------------------
    wire        pixel_valid;
    wire [8:0]  pixel_x;
    wire [7:0]  pixel_y;
    wire [7:0]  pixel_y8;
    wire        frame_start;
    wire        frame_done;
    wire        fb_we;
    wire [14:0] fb_addr;
    wire [7:0]  fb_wdata;
    wire [7:0]  avg_luma;
    wire        vsync_toggle;
    wire        pclk_toggle;

    dvp_capture u_dvp_capture (
        .clk         (clk_pix),
        .rst_n       (video_rst_n),
        .cam_pclk    (cam_pclk),
        .cam_vsync   (cam_vsync),
        .cam_href    (cam_href),
        .cam_data    (cam_data),
        .pixel_valid (pixel_valid),
        .pixel_x     (pixel_x),
        .pixel_y     (pixel_y),
        .pixel_y8    (pixel_y8),
        .frame_start (frame_start),
        .frame_done  (frame_done),
        .fb_we       (fb_we),
        .fb_addr     (fb_addr),
        .fb_wdata    (fb_wdata),
        .avg_luma    (avg_luma),
        .vsync_toggle(vsync_toggle),
        .pclk_toggle (pclk_toggle)
    );

    // -------------------------------------------------------------------------
    // 6. USB-UART Donanım-Döngüde Test (HIL) ve Kare Yakalama Köprüsü
    // -------------------------------------------------------------------------
    wire        hil_active;
    wire        hil_pixel_valid;
    wire [8:0]  hil_pixel_x;
    wire [7:0]  hil_pixel_y;
    wire [7:0]  hil_pixel_y8;
    wire        hil_frame_start;
    wire        hil_frame_done;
    wire        hil_fb_we;
    wire [14:0] hil_fb_addr;
    wire [7:0]  hil_fb_wdata;
    wire        dump_active;
    wire [14:0] dump_fb_addr;

    wire        pupil_valid;
    wire [8:0]  pupil_x;
    wire [7:0]  pupil_y;
    wire [7:0]  active_thresh;
    wire [8:0]  core_x;
    wire [7:0]  core_y;
    wire        glint_valid;
    wire [8:0]  glint_x;
    wire [7:0]  glint_y;

    wire [14:0] fb_rd_addr;
    wire [7:0]  fb_rd_data;

    reg stream_active;

    uart_hil_bridge #(
        .CLK_DIV(27)
    ) u_uart_hil_bridge (
        .clk            (clk_pix),
        .rst_n          (video_rst_n),
        .uart_rx        (uart_rx),
        .uart_tx        (uart_tx),
        .hil_active     (hil_active),
        .hil_pixel_valid(hil_pixel_valid),
        .hil_pixel_x    (hil_pixel_x),
        .hil_pixel_y    (hil_pixel_y),
        .hil_pixel_y8   (hil_pixel_y8),
        .hil_frame_start(hil_frame_start),
        .hil_frame_done (hil_frame_done),
        .hil_fb_we      (hil_fb_we),
        .hil_fb_addr    (hil_fb_addr),
        .hil_fb_wdata   (hil_fb_wdata),
        .dump_active    (dump_active),
        .dump_fb_addr   (dump_fb_addr),
        .dump_fb_data   (fb_rd_data),
        .cam_init_done  (cam_init_done),
        .stream_active  (stream_active),
        .pupil_valid    (pupil_valid),
        .pupil_x        (pupil_x),
        .pupil_y        (pupil_y),
        .core_x         (core_x),
        .core_y         (core_y),
        .active_thresh  (active_thresh),
        .glint_valid    (glint_valid)
    );

    wire        eff_pixel_valid = hil_active ? hil_pixel_valid : pixel_valid;
    wire [8:0]  eff_pixel_x     = hil_active ? hil_pixel_x     : pixel_x;
    wire [7:0]  eff_pixel_y     = hil_active ? hil_pixel_y     : pixel_y;
    wire [7:0]  eff_pixel_y8    = hil_active ? hil_pixel_y8    : pixel_y8;
    wire        eff_frame_start = hil_active ? hil_frame_start : frame_start;
    wire        eff_frame_done  = hil_active ? hil_frame_done  : frame_done;
    wire        eff_fb_we       = hil_active ? hil_fb_we       : fb_we;
    wire [14:0] eff_fb_addr     = hil_active ? hil_fb_addr     : fb_addr;
    wire [7:0]  eff_fb_wdata    = hil_active ? hil_fb_wdata    : fb_wdata;
    wire [14:0] eff_fb_rd_addr  = dump_active ? dump_fb_addr   : fb_rd_addr;

    // -------------------------------------------------------------------------
    // 7. Gerçek Zamanlı Göz Bebeği (Pupil) ve Glint Tespiti (Adım d - v9)
    // -------------------------------------------------------------------------
    pupil_detector u_pupil_detector (
        .clk          (clk_pix),
        .rst_n        (video_rst_n),
        .pixel_valid  (eff_pixel_valid),
        .pixel_x      (eff_pixel_x),
        .pixel_y      (eff_pixel_y),
        .pixel_y8     (eff_pixel_y8),
        .frame_start  (eff_frame_start),
        .frame_done   (eff_frame_done),
        .pupil_valid  (pupil_valid),
        .pupil_x      (pupil_x),
        .pupil_y      (pupil_y),
        .active_thresh(active_thresh),
        .core_x       (core_x),
        .core_y       (core_y),
        .glint_valid  (glint_valid),
        .glint_x      (glint_x),
        .glint_y      (glint_y)
    );

    // -------------------------------------------------------------------------
    // 8. 160x120 @ 8-bit Ping-Pong Çift Tamponlu (Tear-Free) BSRAM Kare Tamponu
    // -------------------------------------------------------------------------
    reg swap_pending;
    always @(posedge clk_pix or negedge video_rst_n) begin
        if (!video_rst_n) begin
            swap_pending <= 1'b0;
        end else if (eff_frame_done && dump_active) begin
            swap_pending <= 1'b1;
        end else if (!dump_active && swap_pending) begin
            swap_pending <= 1'b0;
        end
    end

    wire fb_swap_trig = (eff_frame_done && !dump_active) || (!dump_active && swap_pending);

    frame_buffer_bram u_frame_buffer (
        .clk       (clk_pix),
        .rst_n     (video_rst_n),
        .frame_done(fb_swap_trig),
        .wr_en     (eff_fb_we),
        .wr_addr   (eff_fb_addr),
        .wr_data   (eff_fb_wdata),
        .rd_addr   (eff_fb_rd_addr),
        .rd_data   (fb_rd_data)
    );

    // -------------------------------------------------------------------------
    // 9. 640x480 @ 60Hz Zamanlama, OSD Çizici ve HDMI TMDS Verici
    // -------------------------------------------------------------------------
    wire [9:0] vga_h_cnt;
    wire [9:0] vga_v_cnt;
    wire       vga_hsync;
    wire       vga_vsync;
    wire       vga_de;

    vga_timing_640x480 u_vga_timing (
        .clk_pix(clk_pix),
        .rst_n  (video_rst_n),
        .h_cnt  (vga_h_cnt),
        .v_cnt  (vga_v_cnt),
        .hsync  (vga_hsync),
        .vsync  (vga_vsync),
        .de     (vga_de)
    );

    always @(posedge clk_pix or negedge video_rst_n) begin
        if (!video_rst_n) begin
            stream_active <= 1'b0;
        end else if (eff_fb_we) begin
            stream_active <= 1'b1;
        end
    end

    wire [7:0] osd_r;
    wire [7:0] osd_g;
    wire [7:0] osd_b;
    wire       osd_hsync;
    wire       osd_vsync;
    wire       osd_de;

    osd_renderer u_osd_renderer (
        .clk_pix      (clk_pix),
        .rst_n        (video_rst_n),
        .h_cnt        (vga_h_cnt),
        .v_cnt        (vga_v_cnt),
        .de           (vga_de),
        .fb_rd_addr   (fb_rd_addr),
        .fb_rd_data   (fb_rd_data),
        .cam_init_done(cam_init_done),
        .stream_active(stream_active),
        .avg_luma     (avg_luma),
        .pupil_valid  (pupil_valid),
        .pupil_x      (pupil_x),
        .pupil_y      (pupil_y),
        .active_thresh(active_thresh),
        .core_x       (core_x),
        .core_y       (core_y),
        .glint_valid  (glint_valid),
        .glint_x      (glint_x),
        .glint_y      (glint_y),
        .rgb_r        (osd_r),
        .rgb_g        (osd_g),
        .rgb_b        (osd_b),
        .hsync_out    (osd_hsync),
        .vsync_out    (osd_vsync),
        .de_out       (osd_de),
        .hsync_in     (vga_hsync),
        .vsync_in     (vga_vsync)
    );

    hdmi_tx u_hdmi_tx (
        .clk_pix   (clk_pix),
        .clk_tmds  (clk_tmds),
        .rst_n     (video_rst_n),
        .rgb_r     (osd_r),
        .rgb_g     (osd_g),
        .rgb_b     (osd_b),
        .hsync     (osd_hsync),
        .vsync     (osd_vsync),
        .de        (osd_de),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p  (tmds_d_p),
        .tmds_d_n  (tmds_d_n)
    );

    // -------------------------------------------------------------------------
    // 10. LED Tanılama Çıkışları
    // -------------------------------------------------------------------------
    assign led = ~{
        avg_luma[7],    // LED[5]: Parlaklık MSB
        pupil_valid,    // LED[4]: Göz bebeği tespit edildi (Pupil Lock)
        stream_active,  // LED[3]: Görüntü akışı aktif
        vsync_toggle,   // LED[2]: VSYNC kare sayacı
        pclk_toggle,    // LED[1]: PCLK aktivitesi
        cam_init_done   // LED[0]: SCCB ayarları tamamlandı
    };

endmodule

`default_nettype wire
