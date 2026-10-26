// =============================================================================
// Modül: ov7670_controller
// Açıklama: Açılışta (veya reset sonrasında) ov7670_init_rom içindeki tüm
//           register'ları sccb_master üzerinden OV7670'e yazar.
// =============================================================================
`default_nettype none

module ov7670_controller #(
    parameter integer CLK_FREQ_HZ = 27_000_000
) (
    input  wire clk,
    input  wire rst_n,
    output reg  init_done,
    output wire cam_sioc,
    inout  wire cam_siod
);

    localparam integer DELAY_10MS = (CLK_FREQ_HZ / 100); // ~10 ms

    localparam [2:0] ST_POWERUP_WAIT = 3'd0;
    localparam [2:0] ST_FETCH        = 3'd1;
    localparam [2:0] ST_SEND         = 3'd2;
    localparam [2:0] ST_WAIT_SCCB    = 3'd3;
    localparam [2:0] ST_DELAY_CMD    = 3'd4;
    localparam [2:0] ST_DONE         = 3'd5;

    reg [2:0]  state;
    reg [6:0]  rom_idx;
    reg [19:0] delay_cnt;
    reg        sccb_start;

    wire [15:0] rom_data;
    wire        sccb_busy;
    wire        sccb_done;

    ov7670_init_rom u_rom (
        .index   (rom_idx),
        .reg_pair(rom_data)
    );

    sccb_master #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .SCCB_FREQ_HZ(100_000),
        .DEV_ADDR    (8'h42)
    ) u_sccb (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (sccb_start),
        .reg_addr(rom_data[15:8]),
        .reg_data(rom_data[7:0]),
        .busy    (sccb_busy),
        .done    (sccb_done),
        .sioc    (cam_sioc),
        .siod    (cam_siod)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_POWERUP_WAIT;
            rom_idx    <= 7'd0;
            delay_cnt  <= 20'd0;
            sccb_start <= 1'b0;
            init_done  <= 1'b0;
        end else begin
            sccb_start <= 1'b0;

            case (state)
                // Kamera açılışında XCLK kararlı hale gelene kadar ~10 ms bekle
                ST_POWERUP_WAIT: begin
                    init_done <= 1'b0;
                    if (delay_cnt >= DELAY_10MS - 1) begin
                        delay_cnt <= 20'd0;
                        rom_idx   <= 7'd0;
                        state     <= ST_FETCH;
                    end else begin
                        delay_cnt <= delay_cnt + 20'd1;
                    end
                end

                ST_FETCH: begin
                    if (rom_data == 16'hFF_FF) begin
                        state <= ST_DONE;
                    end else if (rom_data == 16'hFF_00) begin
                        delay_cnt <= 20'd0;
                        state     <= ST_DELAY_CMD;
                    end else begin
                        state <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    if (!sccb_busy) begin
                        sccb_start <= 1'b1;
                        state      <= ST_WAIT_SCCB;
                    end
                end

                ST_WAIT_SCCB: begin
                    if (sccb_done) begin
                        rom_idx <= rom_idx + 7'd1;
                        state   <= ST_FETCH;
                    end
                end

                ST_DELAY_CMD: begin
                    if (delay_cnt >= DELAY_10MS - 1) begin
                        delay_cnt <= 20'd0;
                        rom_idx   <= rom_idx + 7'd1;
                        state     <= ST_FETCH;
                    end else begin
                        delay_cnt <= delay_cnt + 20'd1;
                    end
                end

                ST_DONE: begin
                    init_done <= 1'b1;
                end

                default: state <= ST_POWERUP_WAIT;
            endcase
        end
    end

endmodule

`default_nettype wire
