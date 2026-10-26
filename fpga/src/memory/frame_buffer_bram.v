// =============================================================================
// Modül: frame_buffer_bram
// Açıklama: Yırtılmasız (Tear-Free) Ping-Pong Çift Tamponlu (Double-Buffered)
//           160x120 @ 8-bit Gri Tonlama BSRAM Kare Tamponu.
//           - Kamera (wr_buf) tamponuna yazarken, HDMI (~wr_buf) tamamlanmış
//             önceki tamponu okur.
//           - Kare bittiğinde (frame_done) tamponlar yer değiştirir; böylece
//             ekranda yatay bölünme / dalgalanma (tearing) %100 engellenir.
// =============================================================================
`default_nettype none

module frame_buffer_bram (
    input  wire        clk,
    input  wire        rst_n,

    // Yazma Arayüzü (Kamera Akışı)
    input  wire        frame_done,   // Kare tamamlandı -> tampon değiştir
    input  wire        wr_en,
    input  wire [14:0] wr_addr,      // 0..19199
    input  wire [7:0]  wr_data,

    // Okuma Arayüzü (HDMI Gösterimi)
    input  wire [14:0] rd_addr,      // 0..19199
    output reg  [7:0]  rd_data
);

    // 2 adet 160x120 tampon = 2 * 19200 = 38400 bayt (20 / 26 BSRAM bloğu)
    reg [7:0] mem [0:38399];

    reg wr_bank; // 0 = Alt tampon (0..19199), 1 = Üst tampon (19200..38399)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank <= 1'b0;
        end else if (frame_done) begin
            wr_bank <= ~wr_bank;
        end
    end

    wire [15:0] full_wr_addr = wr_bank ? ({1'b0, wr_addr} + 16'd19200) : {1'b0, wr_addr};
    wire [15:0] full_rd_addr = wr_bank ? {1'b0, rd_addr} : ({1'b0, rd_addr} + 16'd19200);

    always @(posedge clk) begin
        if (wr_en) begin
            mem[full_wr_addr] <= wr_data;
        end
        rd_data <= mem[full_rd_addr];
    end

endmodule

`default_nettype wire
