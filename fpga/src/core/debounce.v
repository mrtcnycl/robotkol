// =============================================================================
// Modül: debounce
// Açıklama: Mekanik buton arkını (glitch/bounce) temizler ve tek saat darbeli
//           (single-cycle pulse) basılma sinyali üretir.
// =============================================================================
`default_nettype none

module debounce #(
    parameter integer CLK_FREQ_HZ = 27_000_000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire btn_in_n,      // Aktif düşük ham buton girişi (0 = basılı)
    output reg  btn_level,     // Temizlenmiş durum (1 = basılı, 0 = serbest)
    output reg  btn_pressed    // Basıldığı anda 1 saat çevrimi '1' olan darbe
);

    localparam integer MAX_COUNT = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

    // 2 kademeli senkronizatör (metastabilite önleme) ve aktif-yükseğe çevirme
    reg sync_0;
    reg sync_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_0 <= 1'b0;
            sync_1 <= 1'b0;
        end else begin
            sync_0 <= ~btn_in_n;
            sync_1 <= sync_0;
        end
    end

    reg [20:0] counter;
    reg        prev_level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter     <= 21'd0;
            btn_level   <= 1'b0;
            prev_level  <= 1'b0;
            btn_pressed <= 1'b0;
        end else begin
            prev_level <= btn_level;

            if (sync_1 != btn_level) begin
                if (counter >= MAX_COUNT - 1) begin
                    btn_level <= sync_1;
                    counter   <= 21'd0;
                end else begin
                    counter <= counter + 21'd1;
                end
            end else begin
                counter <= 21'd0;
            end

            // Yükselen kenar tespiti (butona yeni basıldı)
            btn_pressed <= (btn_level && !prev_level);
        end
    end

endmodule

`default_nettype wire
