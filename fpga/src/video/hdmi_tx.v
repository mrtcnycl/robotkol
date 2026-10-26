// =============================================================================
// Modül: hdmi_tx
// Açıklama: 24-bit RGB + HSYNC/VSYNC/DE sinyallerini TMDS 8b/10b ile kodlayıp
//           Gowin OSER10 (10:1 DDR serileştirici) ve ELVDS_OBUF ile HDMI
//           konnektörüne sürer.
// =============================================================================
`default_nettype none

module hdmi_tx (
    input  wire       clk_pix,     // 25.2 MHz piksel saati
    input  wire       clk_tmds,    // 126.0 MHz 5x DDR TMDS saati
    input  wire       rst_n,
    input  wire [7:0] rgb_r,
    input  wire [7:0] rgb_g,
    input  wire [7:0] rgb_b,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       de,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    wire [9:0] tmds_ch0;
    wire [9:0] tmds_ch1;
    wire [9:0] tmds_ch2;

    tmds_encoder u_enc_b (
        .clk     (clk_pix),
        .rst_n   (rst_n),
        .data_in (rgb_b),
        .ctrl_in ({vsync, hsync}),
        .de      (de),
        .tmds_out(tmds_ch0)
    );

    tmds_encoder u_enc_g (
        .clk     (clk_pix),
        .rst_n   (rst_n),
        .data_in (rgb_g),
        .ctrl_in (2'b00),
        .de      (de),
        .tmds_out(tmds_ch1)
    );

    tmds_encoder u_enc_r (
        .clk     (clk_pix),
        .rst_n   (rst_n),
        .data_in (rgb_r),
        .ctrl_in (2'b00),
        .de      (de),
        .tmds_out(tmds_ch2)
    );

    wire ser_b;
    wire ser_g;
    wire ser_r;
    wire ser_clk;

    OSER10 #(
        .GSREN("false"),
        .LSREN("true")
    ) u_oser_b (
        .Q    (ser_b),
        .D0   (tmds_ch0[0]),
        .D1   (tmds_ch0[1]),
        .D2   (tmds_ch0[2]),
        .D3   (tmds_ch0[3]),
        .D4   (tmds_ch0[4]),
        .D5   (tmds_ch0[5]),
        .D6   (tmds_ch0[6]),
        .D7   (tmds_ch0[7]),
        .D8   (tmds_ch0[8]),
        .D9   (tmds_ch0[9]),
        .PCLK (clk_pix),
        .FCLK (clk_tmds),
        .RESET(~rst_n)
    );

    OSER10 #(
        .GSREN("false"),
        .LSREN("true")
    ) u_oser_g (
        .Q    (ser_g),
        .D0   (tmds_ch1[0]),
        .D1   (tmds_ch1[1]),
        .D2   (tmds_ch1[2]),
        .D3   (tmds_ch1[3]),
        .D4   (tmds_ch1[4]),
        .D5   (tmds_ch1[5]),
        .D6   (tmds_ch1[6]),
        .D7   (tmds_ch1[7]),
        .D8   (tmds_ch1[8]),
        .D9   (tmds_ch1[9]),
        .PCLK (clk_pix),
        .FCLK (clk_tmds),
        .RESET(~rst_n)
    );

    OSER10 #(
        .GSREN("false"),
        .LSREN("true")
    ) u_oser_r (
        .Q    (ser_r),
        .D0   (tmds_ch2[0]),
        .D1   (tmds_ch2[1]),
        .D2   (tmds_ch2[2]),
        .D3   (tmds_ch2[3]),
        .D4   (tmds_ch2[4]),
        .D5   (tmds_ch2[5]),
        .D6   (tmds_ch2[6]),
        .D7   (tmds_ch2[7]),
        .D8   (tmds_ch2[8]),
        .D9   (tmds_ch2[9]),
        .PCLK (clk_pix),
        .FCLK (clk_tmds),
        .RESET(~rst_n)
    );

    OSER10 #(
        .GSREN("false"),
        .LSREN("true")
    ) u_oser_clk (
        .Q    (ser_clk),
        .D0   (1'b1),
        .D1   (1'b1),
        .D2   (1'b1),
        .D3   (1'b1),
        .D4   (1'b1),
        .D5   (1'b0),
        .D6   (1'b0),
        .D7   (1'b0),
        .D8   (1'b0),
        .D9   (1'b0),
        .PCLK (clk_pix),
        .FCLK (clk_tmds),
        .RESET(~rst_n)
    );

    ELVDS_OBUF u_obuf_b   (.I(ser_b),   .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF u_obuf_g   (.I(ser_g),   .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF u_obuf_r   (.I(ser_r),   .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF u_obuf_clk (.I(ser_clk), .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule

`default_nettype wire
