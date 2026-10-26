// =============================================================================
// Modül: clock_pll
// Açıklama: Tang Nano 9K (GW1NR-9C) üzerinde 27 MHz kristalden:
//           - clk_tmds : 126.0 MHz (27 MHz * 14 / 3) -> 5x HDMI DDR saat
//           - clk_pix  :  25.2 MHz (126 MHz / 5)     -> 640x480 @ 60Hz piksel saati
// =============================================================================
`default_nettype none

module clock_pll (
    input  wire clk_27m,
    input  wire rst_n,
    output wire clk_tmds,
    output wire clk_pix,
    output wire pll_lock
);

    wire clkoutp_unused;
    wire clkoutd_unused;
    wire clkoutd3_unused;

    rPLL #(
        .FCLKIN    ("27"),
        .DYN_IDIV_SEL("false"),
        .IDIV_SEL  (2),          // /3  -> 9 MHz
        .DYN_FBDIV_SEL("false"),
        .FBDIV_SEL (13),         // *14 -> 126 MHz
        .DYN_ODIV_SEL("false"),
        .ODIV_SEL  (4),          // VCO = 504 MHz
        .PSDA_SEL  ("0000"),
        .DYN_DA_EN ("true"),
        .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL ("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE    ("GW1NR-9C")
    ) u_rpll (
        .CLKOUT  (clk_tmds),
        .LOCK    (pll_lock),
        .CLKOUTP (clkoutp_unused),
        .CLKOUTD (clkoutd_unused),
        .CLKOUTD3(clkoutd3_unused),
        .RESET   (~rst_n),
        .RESET_P (1'b0),
        .CLKIN   (clk_27m),
        .CLKFB   (1'b0),
        .FBDSEL  (6'd0),
        .IDSEL   (6'd0),
        .ODSEL   (6'd0),
        .PSDA    (4'd0),
        .DUTYDA  (4'd0),
        .FDLY    (4'd0)
    );

    CLKDIV #(
        .DIV_MODE("5"),
        .GSREN   ("false")
    ) u_clkdiv5 (
        .CLKOUT(clk_pix),
        .HCLKIN(clk_tmds),
        .RESETN(rst_n & pll_lock),
        .CALIB (1'b0)
    );

endmodule

`default_nettype wire
