// =============================================================================
// Modül: sccb_master
// Açıklama: OV7670 için 3-fazlı SCCB (I2C uyumlu) yazma sürücüsü.
//           Cihaz Yazma Adresi: 0x42
//           SIOC frekansı: ~100 kHz (27 MHz sistem saatinden)
// =============================================================================
`default_nettype none

module sccb_master #(
    parameter integer CLK_FREQ_HZ  = 27_000_000,
    parameter integer SCCB_FREQ_HZ = 100_000,
    parameter [7:0]   DEV_ADDR     = 8'h42
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,      // Yazma işlemini başlat (1 çevrim darbe)
    input  wire [7:0] reg_addr,   // OV7670 register adresi
    input  wire [7:0] reg_data,   // Yazılacak 8-bit değer
    output reg        busy,       // İşlem devam ediyor
    output reg        done,       // İşlem tamamlandı (1 çevrim darbe)
    output reg        sioc,       // SCCB Saat pini (SCL)
    inout  wire       siod        // SCCB Veri pini (SDA)
);

    // Her bit 4 çeyrek fazdan oluşur:
    //   Faz 0: SIOC = 0 (Veri hazırlanır/değiştirilir)
    //   Faz 1: SIOC = 1 (Veri kararlı)
    //   Faz 2: SIOC = 1 (Veri kararlı)
    //   Faz 3: SIOC = 0 (Tutma süresi)
    localparam integer QUARTER_DIV = CLK_FREQ_HZ / (SCCB_FREQ_HZ * 4);

    reg [15:0] div_cnt;
    wire       tick = (div_cnt == QUARTER_DIV - 1);

    reg [6:0]  step;
    reg [26:0] shift_reg;
    reg        siod_out;
    reg        siod_oe;

    // SCCB veri hattı: OE=1 iken aktif sürülür, 9. bitlerde (Don't-Care) yüksek empedans (Z) bırakılır
    assign siod = siod_oe ? siod_out : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 16'd0;
            step      <= 7'd0;
            shift_reg <= 27'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            sioc      <= 1'b1;
            siod_out  <= 1'b1;
            siod_oe   <= 1'b1;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sioc     <= 1'b1;
                siod_out <= 1'b1;
                siod_oe  <= 1'b1;
                div_cnt  <= 16'd0;
                if (start) begin
                    busy      <= 1'b1;
                    step      <= 7'd0;
                    // 3 x 9 bit = 27 bit: {DEV_ADDR, X, REG_ADDR, X, REG_DATA, X}
                    shift_reg <= {DEV_ADDR, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
                end
            end else begin
                if (tick) begin
                    div_cnt <= 16'd0;
                    step    <= step + 7'd1;

                    case (step)
                        // --- START koşulu ---
                        7'd0: begin sioc <= 1'b1; siod_out <= 1'b1; siod_oe <= 1'b1; end
                        7'd1: begin sioc <= 1'b1; siod_out <= 1'b0; siod_oe <= 1'b1; end
                        7'd2: begin sioc <= 1'b0; siod_out <= 1'b0; siod_oe <= 1'b1; end

                        // --- STOP koşulu (27 bit * 4 faz = 108 adım sonra: 3..110 veri, 111..114 stop) ---
                        7'd111: begin sioc <= 1'b0; siod_out <= 1'b0; siod_oe <= 1'b1; end
                        7'd112: begin sioc <= 1'b1; siod_out <= 1'b0; siod_oe <= 1'b1; end
                        7'd113: begin sioc <= 1'b1; siod_out <= 1'b1; siod_oe <= 1'b1; end
                        7'd114: begin
                            sioc     <= 1'b1;
                            siod_out <= 1'b1;
                            siod_oe  <= 1'b1;
                            busy     <= 1'b0;
                            done     <= 1'b1;
                        end

                        // --- 27 Bit Veri Gönderimi (Adım 3 .. 110) ---
                        default: begin
                            // (step - 3) değerinin alt 2 biti çeyrek fazı, üst 5 biti bit indeksini (0..26) verir
                            case ((step - 7'd3) & 7'd3)
                                7'd0: begin
                                    sioc     <= 1'b0;
                                    siod_out <= shift_reg[26];
                                    // Her 9. bitte (bit_idx == 8, 17, 26) Don't-Care/ACK için hattı serbest bırak
                                    if (((step - 7'd3) >> 2) == 7'd8  ||
                                        ((step - 7'd3) >> 2) == 7'd17 ||
                                        ((step - 7'd3) >> 2) == 7'd26) begin
                                        siod_oe <= 1'b0;
                                    end else begin
                                        siod_oe <= 1'b1;
                                    end
                                end
                                7'd1: begin
                                    sioc <= 1'b1;
                                end
                                7'd2: begin
                                    sioc <= 1'b1;
                                end
                                7'd3: begin
                                    sioc      <= 1'b0;
                                    shift_reg <= {shift_reg[25:0], 1'b0};
                                end
                            endcase
                        end
                    endcase
                end else begin
                    div_cnt <= div_cnt + 16'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
