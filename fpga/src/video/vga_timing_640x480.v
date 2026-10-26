// =============================================================================
// Modül: vga_timing_640x480
// Açıklama: 640x480 @ 60Hz (25.2 MHz piksel saati) standart zamanlama üreteci.
//           Yatay: 640 aktif + 16 ön + 96 senk + 48 arka = 800 toplam
//           Dikey: 480 aktif + 10 ön +  2 senk + 33 arka = 525 toplam
// =============================================================================
`default_nettype none

module vga_timing_640x480 (
    input  wire       clk_pix,
    input  wire       rst_n,
    output reg  [9:0] h_cnt,
    output reg  [9:0] v_cnt,
    output wire       hsync,
    output wire       vsync,
    output wire       de
);

    localparam [9:0] H_ACTIVE = 10'd640;
    localparam [9:0] H_FP     = 10'd16;
    localparam [9:0] H_SYNC   = 10'd96;
    localparam [9:0] H_BP     = 10'd48;
    localparam [9:0] H_TOTAL  = 10'd800;

    localparam [9:0] V_ACTIVE = 10'd480;
    localparam [9:0] V_FP     = 10'd10;
    localparam [9:0] V_SYNC   = 10'd2;
    localparam [9:0] V_BP     = 10'd33;
    localparam [9:0] V_TOTAL  = 10'd525;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end else begin
            if (h_cnt >= H_TOTAL - 10'd1) begin
                h_cnt <= 10'd0;
                if (v_cnt >= V_TOTAL - 10'd1) begin
                    v_cnt <= 10'd0;
                end else begin
                    v_cnt <= v_cnt + 10'd1;
                end
            end else begin
                h_cnt <= h_cnt + 10'd1;
            end
        end
    end

    assign hsync = ~((h_cnt >= H_ACTIVE + H_FP) && (h_cnt < H_ACTIVE + H_FP + H_SYNC));
    assign vsync = ~((v_cnt >= V_ACTIVE + V_FP) && (v_cnt < V_ACTIVE + V_FP + V_SYNC));
    assign de    = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);

endmodule

`default_nettype wire
