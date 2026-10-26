// =============================================================================
// Modül: osd_renderer
// Açıklama: 640x480 HDMI ekranında:
//           1. Ortada 320x240 boyutunda canlı gri tonlama kamera görüntüsünü
//              ve TEK GÖZ boyutundaki (120x64: X=100..220, Y=108..172) ROI
//              hedef çerçevesini gösterir.
//           2. ROI içinde FPGA'nın "göz bebeği (eşiğin altındaki koyu bölge)"
//              olarak algıladığı pikselleri hafif Mavi/Turkuaz tonla renklendirir;
//              böylece algoritmanın nereyi göz bebeği olarak seçtiği canlı görünür!
//           3. Tespit edilen Göz Bebeği (Pupil) merkezine parlak yeşil artı (+)
//              imleci çizer.
// =============================================================================
`default_nettype none

module osd_renderer (
    input  wire        clk_pix,
    input  wire        rst_n,
    input  wire [9:0]  h_cnt,
    input  wire [9:0]  v_cnt,
    input  wire        de,

    // BSRAM Okuma Arayüzü (160x120)
    output wire [14:0] fb_rd_addr,
    input  wire [7:0]  fb_rd_data,

    // Kamera ve Göz Bebeği Durum Bilgileri
    input  wire        cam_init_done,
    input  wire        stream_active,
    input  wire [7:0]  avg_luma,
    input  wire        pupil_valid,
    input  wire [8:0]  pupil_x,      // 0..319
    input  wire [7:0]  pupil_y,      // 0..239
    input  wire [7:0]  active_thresh,// Eşik değeri (maske görselleştirmesi için)
    input  wire [8:0]  core_x,       // En koyu çekirdek X
    input  wire [7:0]  core_y,       // En koyu çekirdek Y
    input  wire        glint_valid,
    input  wire [8:0]  glint_x,
    input  wire [7:0]  glint_y,

    // RGB Çıkışı
    output reg  [7:0]  rgb_r,
    output reg  [7:0]  rgb_g,
    output reg  [7:0]  rgb_b,
    output reg         hsync_out,
    output reg         vsync_out,
    output reg         de_out,
    input  wire        hsync_in,
    input  wire        vsync_in
);

    localparam [9:0] WIN_X0 = 10'd160;
    localparam [9:0] WIN_X1 = 10'd480;
    localparam [9:0] WIN_Y0 = 10'd120;
    localparam [9:0] WIN_Y1 = 10'd360;

    wire in_cam_win = (h_cnt >= WIN_X0 && h_cnt < WIN_X1 &&
                       v_cnt >= WIN_Y0 && v_cnt < WIN_Y1);

    wire on_cam_border = (h_cnt >= WIN_X0 - 10'd2 && h_cnt < WIN_X1 + 10'd2 &&
                          v_cnt >= WIN_Y0 - 10'd2 && v_cnt < WIN_Y1 + 10'd2) && !in_cam_win;

    // Pencere içi 320x240 koordinatları (wx: 0..319, wy: 0..239)
    wire [9:0] wx = h_cnt - WIN_X0;
    wire [9:0] wy = v_cnt - WIN_Y0;

    // 2x büyütme için BSRAM adresi (cam_x: 0..159, cam_y: 0..119)
    wire [7:0] cam_x = wx[8:1];
    wire [6:0] cam_y = wy[7:1];

    assign fb_rd_addr = in_cam_win ? (({cam_y, 7'd0} + {2'd0, cam_y, 5'd0}) + {7'd0, cam_x}) : 15'd0;

    // 1. Tek Göz ROI Kılavuz Çerçevesi (X: 90..230, Y: 104..184) ve Yerel Çekirdek Kutusu
    wire [9:0] dx_core = (wx >= {1'b0, core_x}) ? (wx - {1'b0, core_x}) : ({1'b0, core_x} - wx);
    wire [9:0] dy_core = (wy >= {2'b0, core_y}) ? (wy - {2'b0, core_y}) : ({2'b0, core_y} - wy);
    wire in_local_core = (dx_core <= 10'd13) && (dy_core <= 10'd10);

    wire in_roi_box = in_cam_win && pupil_valid && in_local_core &&
                      (wx >= 10'd90 && wx < 10'd230 && wy >= 10'd104 && wy < 10'd184);

    wire on_roi_border = in_cam_win && (
        ((wx == 10'd90 || wx == 10'd230) && (wy >= 10'd104 && wy <= 10'd184)) ||
        ((wy == 10'd104 || wy == 10'd184) && (wx >= 10'd90 && wx <= 10'd230))
    );

    // 2. Göz Bebeği (Pupil) Artı (+) İmleci, Çerçevesi ve Beyaz Merkez Noktası
    wire [9:0] dx_p = (wx >= {1'b0, pupil_x}) ? (wx - {1'b0, pupil_x}) : ({1'b0, pupil_x} - wx);
    wire [9:0] dy_p = (wy >= {2'b0, pupil_y}) ? (wy - {2'b0, pupil_y}) : ({2'b0, pupil_y} - wy);

    wire on_pupil_center = in_cam_win && pupil_valid && (dx_p <= 10'd2 && dy_p <= 10'd2);

    wire on_pupil_cross = in_cam_win && pupil_valid && (
        ((dx_p <= 10'd1) && (wy >= 10'd104 && wy <= 10'd184)) ||
        ((dy_p <= 10'd1) && (wx >= 10'd90  && wx <= 10'd230)) ||
        ((dx_p == 10'd12 && dy_p <= 10'd10) || (dy_p == 10'd10 && dx_p <= 10'd12))
    );

    // 3. Glint (Kornea Yansıması) Noktası
    wire [9:0] dx_g = (wx >= {1'b0, glint_x}) ? (wx - {1'b0, glint_x}) : ({1'b0, glint_x} - wx);
    wire [9:0] dy_g = (wy >= {2'b0, glint_y}) ? (wy - {2'b0, glint_y}) : ({2'b0, glint_y} - wy);
    wire on_glint_dot = in_cam_win && glint_valid && (dx_g <= 10'd2 && dy_g <= 10'd2);

    // 4. Üst Durum Kutuları (Y: 36..56)
    wire in_init_box   = (v_cnt >= 10'd36 && v_cnt < 10'd56 && h_cnt >= 10'd160 && h_cnt < 10'd195);
    wire in_stream_box = (v_cnt >= 10'd36 && v_cnt < 10'd56 && h_cnt >= 10'd205 && h_cnt < 10'd240);
    wire in_pupil_box  = (v_cnt >= 10'd36 && v_cnt < 10'd56 && h_cnt >= 10'd250 && h_cnt < 10'd285);
    wire in_luma_bar_bg   = (v_cnt >= 10'd36 && v_cnt < 10'd56 && h_cnt >= 10'd295 && h_cnt < 10'd480);
    wire in_luma_bar_fill = in_luma_bar_bg && ((h_cnt - 10'd295) < {2'd0, avg_luma[7:1], 1'b0});

    // 1 çevrim BSRAM okuma gecikmesi dengelemesi
    reg in_cam_win_d;
    reg in_roi_box_d;
    reg on_cam_border_d;
    reg on_roi_border_d;
    reg on_pupil_center_d;
    reg on_pupil_cross_d;
    reg on_glint_dot_d;
    reg in_init_box_d;
    reg in_stream_box_d;
    reg in_pupil_box_d;
    reg in_luma_bar_bg_d;
    reg in_luma_bar_fill_d;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            in_cam_win_d       <= 1'b0;
            in_roi_box_d       <= 1'b0;
            on_cam_border_d    <= 1'b0;
            on_roi_border_d    <= 1'b0;
            on_pupil_center_d  <= 1'b0;
            on_pupil_cross_d   <= 1'b0;
            on_glint_dot_d     <= 1'b0;
            in_init_box_d      <= 1'b0;
            in_stream_box_d    <= 1'b0;
            in_pupil_box_d     <= 1'b0;
            in_luma_bar_bg_d   <= 1'b0;
            in_luma_bar_fill_d <= 1'b0;
            hsync_out          <= 1'b1;
            vsync_out          <= 1'b1;
            de_out             <= 1'b0;
            rgb_r              <= 8'd0;
            rgb_g              <= 8'd0;
            rgb_b              <= 8'd0;
        end else begin
            in_cam_win_d       <= in_cam_win;
            in_roi_box_d       <= in_roi_box;
            on_cam_border_d    <= on_cam_border;
            on_roi_border_d    <= on_roi_border;
            on_pupil_center_d  <= on_pupil_center;
            on_pupil_cross_d   <= on_pupil_cross;
            on_glint_dot_d     <= on_glint_dot;
            in_init_box_d      <= in_init_box;
            in_stream_box_d    <= in_stream_box;
            in_pupil_box_d     <= in_pupil_box;
            in_luma_bar_bg_d   <= in_luma_bar_bg;
            in_luma_bar_fill_d <= in_luma_bar_fill;
            hsync_out          <= hsync_in;
            vsync_out          <= vsync_in;
            de_out             <= de;

            if (!de) begin
                rgb_r <= 8'd0;
                rgb_g <= 8'd0;
                rgb_b <= 8'd0;
            end else if (on_pupil_center_d) begin
                // Göz bebeği tam merkezi: Parlak Beyaz Nokta
                rgb_r <= 8'd255;
                rgb_g <= 8'd255;
                rgb_b <= 8'd255;
            end else if (on_pupil_cross_d) begin
                // Göz bebeği hedef artısı (+) ve kutusu: Parlak Yeşil
                rgb_r <= 8'd0;
                rgb_g <= 8'd255;
                rgb_b <= 8'd60;
            end else if (on_glint_dot_d) begin
                // Kornea yansıması (Glint): Parlak Sarı Nokta
                rgb_r <= 8'd255;
                rgb_g <= 8'd230;
                rgb_b <= 8'd0;
            end else if (on_roi_border_d) begin
                // Tek-Göz ROI Çerçevesi: Parlak Turkuaz
                rgb_r <= 8'd0;
                rgb_g <= 8'd220;
                rgb_b <= 8'd255;
            end else if (in_cam_win_d) begin
                if (in_roi_box_d && (fb_rd_data <= active_thresh)) begin
                    // Eşiğin altındaki (Göz bebeği olarak algılanan) pikselleri
                    // hafif Kırmızı/Macenta tonla göster ki nereyi algıladığı net görülsün!
                    rgb_r <= 8'd180;
                    rgb_g <= fb_rd_data;
                    rgb_b <= fb_rd_data + 8'd40;
                end else begin
                    rgb_r <= fb_rd_data;
                    rgb_g <= fb_rd_data;
                    rgb_b <= fb_rd_data;
                end
            end else if (on_cam_border_d) begin
                rgb_r <= stream_active ? 8'd0   : 8'd220;
                rgb_g <= stream_active ? 8'd200 : 8'd40;
                rgb_b <= stream_active ? 8'd255 : 8'd40;
            end else if (in_init_box_d) begin
                rgb_r <= cam_init_done ? 8'd30  : 8'd220;
                rgb_g <= cam_init_done ? 8'd220 : 8'd30;
                rgb_b <= 8'd40;
            end else if (in_stream_box_d) begin
                rgb_r <= stream_active ? 8'd30  : 8'd240;
                rgb_g <= stream_active ? 8'd220 : 8'd140;
                rgb_b <= 8'd30;
            end else if (in_pupil_box_d) begin
                rgb_r <= pupil_valid ? 8'd20  : 8'd180;
                rgb_g <= pupil_valid ? 8'd230 : 8'd40;
                rgb_b <= 8'd60;
            end else if (in_luma_bar_fill_d) begin
                rgb_r <= 8'd60;
                rgb_g <= 8'd180;
                rgb_b <= 8'd255;
            end else if (in_luma_bar_bg_d) begin
                rgb_r <= 8'd40;
                rgb_g <= 8'd45;
                rgb_b <= 8'd55;
            end else begin
                rgb_r <= 8'd18;
                rgb_g <= 8'd22;
                rgb_b <= 8'd30;
            end
        end
    end

endmodule

`default_nettype wire
