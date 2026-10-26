// =============================================================================
// Modül: system_fsm
// Açıklama: Göz takip sisteminin ana durum makinesi.
//           Durumlar:
//             0 (STATE_IDLE)        : Kamera önizleme ve bekleme modu
//             1 (STATE_CALIBRATING) : 5 noktalı kalibrasyon (SolÜst, SağÜst, Merkez, SolAlt, SağAlt)
//             2 (STATE_TRACKING)    : Canlı bakış noktası (gaze) takip modu
// =============================================================================
`default_nettype none

module system_fsm #(
    parameter integer NUM_CALIB_POINTS = 5
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       action_pulse,     // S2 butonu tek darbe (onay / durum geçişi)
    output reg  [1:0] state,            // Aktif durum
    output reg  [2:0] calib_index,      // Aktif kalibrasyon noktası indeksi (0..4)
    output reg        sample_capture    // Kalibrasyon noktasını kaydetme tetikleyicisi
);

    localparam [1:0] STATE_IDLE        = 2'd0;
    localparam [1:0] STATE_CALIBRATING = 2'd1;
    localparam [1:0] STATE_TRACKING    = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= STATE_IDLE;
            calib_index    <= 3'd0;
            sample_capture <= 1'b0;
        end else begin
            sample_capture <= 1'b0;

            if (action_pulse) begin
                case (state)
                    STATE_IDLE: begin
                        state       <= STATE_CALIBRATING;
                        calib_index <= 3'd0;
                    end

                    STATE_CALIBRATING: begin
                        sample_capture <= 1'b1;
                        if (calib_index >= NUM_CALIB_POINTS - 1) begin
                            state       <= STATE_TRACKING;
                            calib_index <= 3'd0;
                        end else begin
                            calib_index <= calib_index + 3'd1;
                        end
                    end

                    STATE_TRACKING: begin
                        // Takip modundayken S2'ye basılırsa yeniden kalibrasyona girer
                        state       <= STATE_CALIBRATING;
                        calib_index <= 3'd0;
                    end

                    default: begin
                        state       <= STATE_IDLE;
                        calib_index <= 3'd0;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
