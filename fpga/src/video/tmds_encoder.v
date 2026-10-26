// =============================================================================
// Modül: tmds_encoder
// Açıklama: DVI / HDMI 1.0 uyumlu 8b/10b TMDS (Transition Minimized
//           Differential Signaling) kodlayıcı.
// =============================================================================
`default_nettype none

module tmds_encoder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data_in,
    input  wire [1:0] ctrl_in,
    input  wire       de,
    output reg  [9:0] tmds_out
);

    // 8-bit girişteki '1' sayısı
    wire [3:0] n1_d = data_in[0] + data_in[1] + data_in[2] + data_in[3] +
                      data_in[4] + data_in[5] + data_in[6] + data_in[7];

    wire use_xnor = (n1_d > 4'd4) || (n1_d == 4'd4 && data_in[0] == 1'b0);

    wire [8:0] q_m;
    assign q_m[0] = data_in[0];
    assign q_m[1] = use_xnor ? ~(q_m[0] ^ data_in[1]) : (q_m[0] ^ data_in[1]);
    assign q_m[2] = use_xnor ? ~(q_m[1] ^ data_in[2]) : (q_m[1] ^ data_in[2]);
    assign q_m[3] = use_xnor ? ~(q_m[2] ^ data_in[3]) : (q_m[2] ^ data_in[3]);
    assign q_m[4] = use_xnor ? ~(q_m[3] ^ data_in[4]) : (q_m[3] ^ data_in[4]);
    assign q_m[5] = use_xnor ? ~(q_m[4] ^ data_in[5]) : (q_m[4] ^ data_in[5]);
    assign q_m[6] = use_xnor ? ~(q_m[5] ^ data_in[6]) : (q_m[5] ^ data_in[6]);
    assign q_m[7] = use_xnor ? ~(q_m[6] ^ data_in[7]) : (q_m[6] ^ data_in[7]);
    assign q_m[8] = use_xnor ? 1'b0 : 1'b1;

    wire [3:0] n1_qm = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                       q_m[4] + q_m[5] + q_m[6] + q_m[7];
    wire [3:0] n0_qm = 4'd8 - n1_qm;

    reg signed [4:0] disparity;

    wire signed [4:0] diff_qm = $signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmds_out  <= 10'b1101010100;
            disparity <= 5'sd0;
        end else if (!de) begin
            disparity <= 5'sd0;
            case (ctrl_in)
                2'b00: tmds_out <= 10'b1101010100;
                2'b01: tmds_out <= 10'b0010101011;
                2'b10: tmds_out <= 10'b0101010100;
                2'b11: tmds_out <= 10'b1010101011;
            endcase
        end else begin
            if (disparity == 5'sd0 || (n1_qm == 4'd4)) begin
                tmds_out[9]   <= ~q_m[8];
                tmds_out[8]   <= q_m[8];
                tmds_out[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
                if (q_m[8] == 1'b0) begin
                    disparity <= disparity - diff_qm;
                end else begin
                    disparity <= disparity + diff_qm;
                end
            end else if ((disparity > 5'sd0 && n1_qm > 4'd4) ||
                         (disparity < 5'sd0 && n1_qm < 4'd4)) begin
                tmds_out[9]   <= 1'b1;
                tmds_out[8]   <= q_m[8];
                tmds_out[7:0] <= ~q_m[7:0];
                disparity     <= disparity + $signed({3'b0, q_m[8], 1'b0}) - diff_qm;
            end else begin
                tmds_out[9]   <= 1'b0;
                tmds_out[8]   <= q_m[8];
                tmds_out[7:0] <= q_m[7:0];
                disparity     <= disparity - $signed({3'b0, ~q_m[8], 1'b0}) + diff_qm;
            end
        end
    end

endmodule

`default_nettype wire
