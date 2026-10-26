// =============================================================================
// Modül: uart_hil_bridge
// Açıklama: Tang Nano 9K üzerindeki BL702 USB-UART (Pin 18 = RX, Pin 17 = TX)
//           üzerinden çift yönlü Donanım-Döngüde (HIL) Test ve Yüksek Hızlı
//           Canlı Kamera Kare Yakalama Köprüsü (921600 baud, 8N1).
//
// Komut Protokolü (Bilgisayar -> FPGA):
//   1. [0x54 ('T')] : Canlı Telemetri Sorgusu (8 bayt)
//   2. [0xC5]       : Tam Çözünürlüklü Kare + Telemetri (8 + 19200 = 19208 bayt, 160x120)
//   3. [0xC6]       : Turbo Canlı Akış Modu (8 + 4800 = 4808 bayt, 80x60 @ ~19.2 FPS!)
//   4. [0x5A, 0xA5 + 40960 bayt] : HIL Video Karesi Enjeksiyonu (256x160) -> 8 bayt yanıt
// =============================================================================
`default_nettype none

module uart_hil_bridge #(
    parameter integer CLK_DIV = 27 // 25.2 MHz / 921600 baud = 27.34 (-1.2% hata)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx,
    output reg         uart_tx,

    // HIL Piksel Akışı Çıkışı (pupil_detector ve frame_buffer_bram'e bağlanır)
    output reg         hil_active,
    output reg         hil_pixel_valid,
    output reg  [8:0]  hil_pixel_x,
    output reg  [7:0]  hil_pixel_y,
    output reg  [7:0]  hil_pixel_y8,
    output reg         hil_frame_start,
    output reg         hil_frame_done,
    output reg         hil_fb_we,
    output reg  [14:0] hil_fb_addr,
    output reg  [7:0]  hil_fb_wdata,

    // Canlı Kare Okuma (Frame Dump) Arayüzü (frame_buffer_bram'e bağlanır)
    output reg         dump_active,
    output reg  [14:0] dump_fb_addr,
    input  wire [7:0]  dump_fb_data,

    // Telemetri Girişleri (pupil_detector ve kamera durumları)
    input  wire        cam_init_done,
    input  wire        stream_active,
    input  wire        pupil_valid,
    input  wire [8:0]  pupil_x,
    input  wire [7:0]  pupil_y,
    input  wire [8:0]  core_x,
    input  wire [7:0]  core_y,
    input  wire [7:0]  active_thresh,
    input  wire        glint_valid
);

    // -------------------------------------------------------------------------
    // 1. UART Alıcı (8N1, 921600 baud)
    // -------------------------------------------------------------------------
    reg rx_s0, rx_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1;
            rx_s1 <= 1'b1;
        end else begin
            rx_s0 <= uart_rx;
            rx_s1 <= rx_s0;
        end
    end

    reg [1:0] rx_state;
    reg [5:0] rx_clk_cnt;
    reg [2:0] rx_bit_idx;
    reg [7:0] rx_shift;
    reg       rx_valid;
    reg [7:0] rx_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state   <= 2'd0;
            rx_clk_cnt <= 6'd0;
            rx_bit_idx <= 3'd0;
            rx_shift   <= 8'd0;
            rx_valid   <= 1'b0;
            rx_byte    <= 8'd0;
        end else begin
            rx_valid <= 1'b0;
            case (rx_state)
                2'd0: begin
                    if (!rx_s1) begin
                        rx_clk_cnt <= 6'd0;
                        rx_state   <= 2'd1;
                    end
                end
                2'd1: begin
                    if (rx_clk_cnt >= (CLK_DIV / 2) - 1) begin
                        if (!rx_s1) begin
                            rx_clk_cnt <= 6'd0;
                            rx_bit_idx <= 3'd0;
                            rx_state   <= 2'd2;
                        end else begin
                            rx_state <= 2'd0;
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 6'd1;
                    end
                end
                2'd2: begin
                    if (rx_clk_cnt >= CLK_DIV - 1) begin
                        rx_clk_cnt           <= 6'd0;
                        rx_shift[rx_bit_idx] <= rx_s1;
                        if (rx_bit_idx == 3'd7) begin
                            rx_state <= 2'd3;
                        end else begin
                            rx_bit_idx <= rx_bit_idx + 3'd1;
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 6'd1;
                    end
                end
                2'd3: begin
                    if (rx_clk_cnt >= CLK_DIV - 1) begin
                        rx_valid <= 1'b1;
                        rx_byte  <= rx_shift;
                        rx_state <= 2'd0;
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt + 6'd1;
                    end
                end
                default: rx_state <= 2'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. Komut ve HIL Kare Alıcı Durum Makinesi
    // -------------------------------------------------------------------------
    localparam [1:0] CMD_IDLE     = 2'd0;
    localparam [1:0] CMD_WAIT_A5  = 2'd1;
    localparam [1:0] CMD_HIL_STRM = 2'd2;
    localparam [1:0] CMD_HIL_END  = 2'd3;

    reg [1:0]  cmd_state;
    reg [23:0] watchdog_cnt;
    reg [4:0]  end_wait_cnt;
    reg        trig_telem_only;
    reg        trig_frame_dump;
    reg        trig_fast_dump;

    wire [6:0]  hil_y_sub = hil_pixel_y[7:1];
    wire [7:0]  hil_x_sub = hil_pixel_x[8:1];
    wire [14:0] next_hil_fb_addr = ({hil_y_sub, 7'd0} + {2'd0, hil_y_sub, 5'd0}) + {7'd0, hil_x_sub};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_state       <= CMD_IDLE;
            hil_active      <= 1'b0;
            hil_pixel_valid <= 1'b0;
            hil_pixel_x     <= 9'd287;
            hil_pixel_y     <= 8'd64;
            hil_pixel_y8    <= 8'd0;
            hil_frame_start <= 1'b0;
            hil_frame_done  <= 1'b0;
            hil_fb_we       <= 1'b0;
            hil_fb_addr     <= 15'd0;
            hil_fb_wdata    <= 8'd0;
            watchdog_cnt    <= 24'd0;
            end_wait_cnt    <= 5'd0;
            trig_telem_only <= 1'b0;
            trig_frame_dump <= 1'b0;
            trig_fast_dump  <= 1'b0;
        end else begin
            hil_pixel_valid <= 1'b0;
            hil_frame_start <= 1'b0;
            hil_frame_done  <= 1'b0;
            hil_fb_we       <= 1'b0;
            trig_telem_only <= 1'b0;
            trig_frame_dump <= 1'b0;
            trig_fast_dump  <= 1'b0;

            if (rx_valid) begin
                watchdog_cnt <= 24'd12_600_000;
            end else if (watchdog_cnt > 24'd0) begin
                watchdog_cnt <= watchdog_cnt - 24'd1;
            end else begin
                hil_active <= 1'b0;
                if (cmd_state == CMD_HIL_STRM || cmd_state == CMD_WAIT_A5) begin
                    cmd_state <= CMD_IDLE;
                end
            end

            case (cmd_state)
                CMD_IDLE: begin
                    if (rx_valid) begin
                        if (rx_byte == 8'h5A) begin
                            cmd_state <= CMD_WAIT_A5;
                        end else if (rx_byte == 8'h54) begin // 'T': Sadece 8-bayt telemetri
                            trig_telem_only <= 1'b1;
                        end else if (rx_byte == 8'hC5) begin // 0xC5: 8 + 19200 bayt (160x120)
                            trig_frame_dump <= 1'b1;
                        end else if (rx_byte == 8'hC6) begin // 0xC6: 8 + 4800 bayt (80x60 Turbo)
                            trig_fast_dump <= 1'b1;
                        end else if (rx_byte == 8'h00) begin
                            hil_active <= 1'b0;
                        end
                    end
                end

                CMD_WAIT_A5: begin
                    if (rx_valid) begin
                        if (rx_byte == 8'hA5) begin
                            hil_active      <= 1'b1;
                            hil_frame_start <= 1'b1;
                            hil_pixel_x     <= 9'd287;
                            hil_pixel_y     <= 8'd64;
                            cmd_state       <= CMD_HIL_STRM;
                        end else if (rx_byte != 8'h5A) begin
                            cmd_state <= CMD_IDLE;
                        end
                    end
                end

                CMD_HIL_STRM: begin
                    if (rx_valid) begin
                        hil_pixel_valid <= 1'b1;
                        hil_pixel_y8    <= rx_byte;

                        if (hil_pixel_x[0] == 1'b0 && hil_pixel_y[0] == 1'b0) begin
                            hil_fb_we    <= 1'b1;
                            hil_fb_addr  <= next_hil_fb_addr;
                            hil_fb_wdata <= rx_byte;
                        end

                        if (hil_pixel_x == 9'd32) begin
                            hil_pixel_x <= 9'd287;
                            if (hil_pixel_y == 8'd223) begin
                                hil_pixel_y  <= 8'd64;
                                end_wait_cnt <= 5'd0;
                                cmd_state    <= CMD_HIL_END;
                            end else begin
                                hil_pixel_y <= hil_pixel_y + 8'd1;
                            end
                        end else begin
                            hil_pixel_x <= hil_pixel_x - 9'd1;
                        end
                    end
                end

                CMD_HIL_END: begin
                    end_wait_cnt <= end_wait_cnt + 5'd1;
                    if (end_wait_cnt == 5'd8) begin
                        hil_frame_done <= 1'b1;
                    end else if (end_wait_cnt == 5'd24) begin
                        trig_telem_only <= 1'b1;
                        cmd_state       <= CMD_IDLE;
                    end
                end

                default: cmd_state <= CMD_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 3. UART Verici (8-Bayt Telemetri + 160x120 veya 80x60 Kare Görüntüsü)
    // -------------------------------------------------------------------------
    localparam [2:0] TX_IDLE      = 3'd0;
    localparam [2:0] TX_SEND_HDR  = 3'd1;
    localparam [2:0] TX_WAIT_HDR  = 3'd2;
    localparam [2:0] TX_FB_RD_1   = 3'd3;
    localparam [2:0] TX_FB_RD_2   = 3'd4;
    localparam [2:0] TX_WAIT_FB   = 3'd5;

    reg [2:0] tx_state;
    reg [7:0] pkt_buf [0:7];
    reg [3:0] pkt_idx;
    reg       want_fb_dump;
    reg       fast_80x60;
    reg [6:0] sub_col_cnt;

    reg       uart_busy;
    reg       uart_start;
    reg [7:0] uart_data;
    reg [5:0] tx_clk_cnt;
    reg [3:0] tx_bit_idx;
    reg [9:0] tx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx    <= 1'b1;
            uart_busy  <= 1'b0;
            tx_clk_cnt <= 6'd0;
            tx_bit_idx <= 4'd0;
            tx_shift   <= 10'h3FF;
        end else begin
            if (uart_start && !uart_busy) begin
                tx_shift   <= {1'b1, uart_data, 1'b0};
                tx_clk_cnt <= 6'd0;
                tx_bit_idx <= 4'd0;
                uart_busy  <= 1'b1;
            end else if (uart_busy) begin
                uart_tx <= tx_shift[0];
                if (tx_clk_cnt >= CLK_DIV - 1) begin
                    tx_clk_cnt <= 6'd0;
                    tx_shift   <= {1'b1, tx_shift[9:1]};
                    if (tx_bit_idx == 4'd9) begin
                        uart_busy <= 1'b0;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 4'd1;
                    end
                end else begin
                    tx_clk_cnt <= tx_clk_cnt + 6'd1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            pkt_idx      <= 4'd0;
            want_fb_dump <= 1'b0;
            fast_80x60   <= 1'b0;
            sub_col_cnt  <= 7'd0;
            dump_active  <= 1'b0;
            dump_fb_addr <= 15'd0;
            uart_start   <= 1'b0;
            uart_data    <= 8'd0;
        end else begin
            uart_start <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    dump_active <= 1'b0;
                    if (trig_telem_only || trig_frame_dump || trig_fast_dump) begin
                        pkt_buf[0]   <= 8'hAA;
                        pkt_buf[1]   <= 8'h55;
                        pkt_buf[2]   <= {hil_active, cam_init_done, stream_active, glint_valid, 1'b0, core_x[8], pupil_x[8], pupil_valid};
                        pkt_buf[3]   <= pupil_x[7:0];
                        pkt_buf[4]   <= pupil_y[7:0];
                        pkt_buf[5]   <= core_x[7:0];
                        pkt_buf[6]   <= core_y[7:0];
                        pkt_buf[7]   <= active_thresh[7:0];
                        pkt_idx      <= 4'd0;
                        want_fb_dump <= (trig_frame_dump || trig_fast_dump);
                        fast_80x60   <= trig_fast_dump;
                        sub_col_cnt  <= 7'd0;
                        dump_active  <= (trig_frame_dump || trig_fast_dump);
                        dump_fb_addr <= 15'd0;
                        tx_state     <= TX_SEND_HDR;
                    end
                end

                TX_SEND_HDR: begin
                    if (!uart_busy && !uart_start) begin
                        uart_data  <= pkt_buf[pkt_idx];
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_HDR;
                    end
                end

                TX_WAIT_HDR: begin
                    if (!uart_busy && !uart_start) begin
                        if (pkt_idx == 4'd7) begin
                            if (want_fb_dump) begin
                                dump_fb_addr <= 15'd0;
                                sub_col_cnt  <= 7'd0;
                                tx_state     <= TX_FB_RD_1;
                            end else begin
                                tx_state <= TX_IDLE;
                            end
                        end else begin
                            pkt_idx  <= pkt_idx + 4'd1;
                            tx_state <= TX_SEND_HDR;
                        end
                    end
                end

                TX_FB_RD_1: begin
                    tx_state <= TX_FB_RD_2;
                end

                TX_FB_RD_2: begin
                    if (!uart_busy && !uart_start) begin
                        uart_data  <= dump_fb_data;
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_FB;
                    end
                end

                TX_WAIT_FB: begin
                    if (!uart_busy && !uart_start) begin
                        if (fast_80x60) begin
                            if (dump_fb_addr >= 15'd19038) begin
                                dump_active <= 1'b0;
                                tx_state    <= TX_IDLE;
                            end else if (sub_col_cnt >= 7'd79) begin
                                sub_col_cnt  <= 7'd0;
                                dump_fb_addr <= dump_fb_addr + 15'd162;
                                tx_state     <= TX_FB_RD_1;
                            end else begin
                                sub_col_cnt  <= sub_col_cnt + 7'd1;
                                dump_fb_addr <= dump_fb_addr + 15'd2;
                                tx_state     <= TX_FB_RD_1;
                            end
                        end else begin
                            if (dump_fb_addr >= 15'd19199) begin
                                dump_active <= 1'b0;
                                tx_state    <= TX_IDLE;
                            end else begin
                                dump_fb_addr <= dump_fb_addr + 15'd1;
                                tx_state     <= TX_FB_RD_1;
                            end
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
