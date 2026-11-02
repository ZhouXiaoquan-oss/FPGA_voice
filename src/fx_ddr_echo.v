// fx_ddr_echo -- D2 single-tap DDR3 echo mixer (0.5/1/2/4 s, no feedback).
//
// Mounted after sample_trem (x[n] valid from clk#17 after frame_tick):
//   capture x at clk#18, service returns q at clk#32, mix registered clk#33,
//   PT8211 latches at the NEXT frame_tick -> no extra audio-frame latency.
//
// Off (stable): sample_out = sample_in, purely combinational, bit-exact.
// On  (stable): sample_out = (signed(x) + signed(q)) >>> 1.
// Enable/disable and tap changes use a 256-frame linear ramp/crossfade.
// service_ready=0 -> fade to dry within ~64 frames and clear want_on;
// a new enable command is required after recovery (frozen contract).
//
// ASCII only. No feedback path. No Looper.

module fx_ddr_echo #(
    parameter integer FADE_LEN  = 256,
    parameter integer CAP_SLOT  = 18,   // x capture slot after frame_tick
    parameter integer MIX_SLOT  = 33    // q is stable from slot 32; register at 33
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               frame_tick,

    input  wire signed [15:0] sample_in,      // x[n] = sample_trem
    input  wire               enable_toggle,  // 1-clk request pulse (UART 0x13)
    input  wire               delay_cycle,    // 1-clk request pulse (UART 0x14)

    input  wire signed [15:0] q0,             // service tap0 (active)
    input  wire signed [15:0] q1,             // service tap1 (pending)
    input  wire               q0_valid,
    input  wire               q1_valid,
    input  wire               service_ready,

    output reg  [1:0]         tap0_sel,
    output reg  [1:0]         tap1_sel,
    output wire signed [15:0] sample_out,
    output reg  [7:0]         dbg_state,
    output reg  [15:0]        dbg_gain
);

    localparam [2:0] S_OFF       = 3'd0,
                     S_WAIT_WARM = 3'd1,
                     S_FADE_IN   = 3'd2,
                     S_ON        = 3'd3,
                     S_WAIT_NEW  = 3'd4,
                     S_CROSSFADE = 3'd5,
                     S_FADE_OUT  = 3'd6,
                     S_FAULT_OFF = 3'd7;

    reg [2:0]  state;
    reg [8:0]  gain;          // 0..256
    reg [8:0]  q_ramp;        // 0..256: wet branch starts at 0, ramps once valid
    reg [7:0]  xf_idx;        // 0..255
    reg [7:0]  warm_cnt;
    reg        want_on;
    reg [1:0]  delay_req;

    // command pulses -> sticky requests, applied only at a frame boundary.
    // Split into two always blocks: Gowin V1.9.11 rejects two independent
    // nonblocking if-chains for different regs inside one always (EX2711).
    reg en_req_q, dly_req_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en_req_q <= 1'b0;
        end else if (enable_toggle) begin
            en_req_q <= 1'b1;
        end else if (frame_tick) begin
            en_req_q <= 1'b0;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dly_req_q <= 1'b0;
        end else if (delay_cycle) begin
            dly_req_q <= 1'b1;
        end else if (frame_tick) begin
            dly_req_q <= 1'b0;
        end
    end
    wire [1:0] dly_next = (delay_req == 2'd3) ? 2'd0 : (delay_req + 2'd1);

    reg signed [15:0] x_cap;
    reg signed [15:0] q0_cap, q1_cap;
    reg        q0v_cap, q1v_cap;
    reg [10:0] slot;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot    <= 11'd0;
            x_cap   <= 16'sd0;
            q0_cap  <= 16'sd0;
            q1_cap  <= 16'sd0;
            q0v_cap <= 1'b0;
            q1v_cap <= 1'b0;
        end else if (frame_tick) begin
            slot <= 11'd0;
        end else begin
            slot <= slot + 11'd1;
            if (slot == CAP_SLOT - 1) begin
                x_cap <= sample_in;               // x stable from clk#17
            end
            if (slot == MIX_SLOT) begin           // service q registered at slot 32
                q0_cap  <= q0;
                q1_cap  <= q1;
                q0v_cap <= q0_valid;
                q1v_cap <= q1_valid;
            end
        end
    end

    // ---------------------------------------------------------------- FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_OFF;
            gain      <= 9'd0;
            q_ramp    <= 9'd0;
            xf_idx    <= 8'd0;
            warm_cnt  <= 8'd0;
            want_on   <= 1'b0;
            delay_req <= 2'd0;
            tap0_sel  <= 2'd0;
            tap1_sel  <= 2'd0;
        end else if (!service_ready) begin
            want_on <= 1'b0;
            q_ramp  <= 9'd0;
            if (state != S_OFF) begin
                if (frame_tick) begin
                    if (gain > 9'd4) begin
                        gain <= gain - 9'd4;
                    end else begin
                        gain  <= 9'd0;
                        state <= S_OFF;
                    end
                end
            end else begin
                gain  <= 9'd0;
                state <= S_OFF;
            end
        end else if (frame_tick) begin

            // ---- command apply at frame boundary ----
            if (en_req_q) begin
                if (!want_on) begin
                    want_on   <= 1'b1;
                    delay_req <= dly_req_q ? dly_next : delay_req;
                    if (state == S_OFF) begin
                        tap0_sel <= dly_req_q ? dly_next : delay_req;
                        tap1_sel <= dly_req_q ? dly_next : delay_req;
                        // Contract: healthy startup with n<D keeps the wet branch
                        // at 0, i.e. y=(x+0)>>1. q_ramp brings the real q in
                        // smoothly once history becomes valid (no step/click).
                        state    <= S_FADE_IN;
                        warm_cnt <= 8'd0;
                        gain     <= 9'd0;
                        q_ramp   <= 9'd0;
                    end
                end else begin
                    want_on <= 1'b0;
                    if (state == S_ON || state == S_FADE_IN) state <= S_FADE_OUT;
                end
            end else if (dly_req_q) begin
                delay_req <= dly_next;
                if (state == S_OFF) begin
                    tap0_sel <= dly_next;
                    tap1_sel <= dly_next;
                end
            end

            // wet-branch ramp: reset while the active history is invalid,
            // advance to full scale when q0 becomes valid
            if (state == S_ON || state == S_FADE_IN || state == S_CROSSFADE) begin
                if (q0_valid) begin
                    if (q_ramp < 9'd256) q_ramp <= q_ramp + 9'd1;
                end else begin
                    q_ramp <= 9'd0;
                end
            end else begin
                q_ramp <= 9'd0;
            end

            // pending delay request while ON -> prepare new tap stream
            if ((state == S_ON) && (delay_req != tap0_sel)) begin
                tap1_sel <= delay_req;
                state    <= S_WAIT_NEW;
                warm_cnt <= 8'd0;
            end

            case (state)
                S_OFF: begin
                    gain <= 9'd0;
                end
                S_WAIT_WARM: begin
                    if (q0_valid) begin
                        if (warm_cnt == 8'd7) begin
                            state <= S_FADE_IN;
                            gain  <= 9'd0;
                        end else warm_cnt <= warm_cnt + 8'd1;
                    end else warm_cnt <= 8'd0;
                end
                S_FADE_IN: begin
                    if (gain >= 9'd255) begin
                        gain  <= 9'd256;
                        state <= S_ON;
                    end else gain <= gain + 9'd1;
                end
                S_ON: begin
                    gain <= 9'd256;
                end
                S_WAIT_NEW: begin
                    if (q1_valid) begin
                        if (warm_cnt == 8'd7) begin
                            state  <= S_CROSSFADE;
                            xf_idx <= 8'd0;
                        end else warm_cnt <= warm_cnt + 8'd1;
                    end else warm_cnt <= 8'd0;
                end
                S_CROSSFADE: begin
                    if (xf_idx == FADE_LEN - 1) begin
                        tap0_sel <= tap1_sel;
                        xf_idx   <= 8'd0;
                        state    <= S_ON;
                    end else xf_idx <= xf_idx + 8'd1;
                end
                S_FADE_OUT: begin
                    if (gain == 9'd0) begin
                        state <= S_OFF;
                    end else if (!service_ready) begin
                        gain <= (gain > 9'd4) ? gain - 9'd4 : 9'd0;
                    end else begin
                        gain <= gain - 9'd1;
                    end
                end
                S_FAULT_OFF: state <= S_OFF;
                default:     state <= S_OFF;
            endcase
        end
    end

    // ------------------------------------------------------------- mix math
    wire signed [15:0] q0_s = q0v_cap ? q0_cap : 16'sd0;
    wire signed [15:0] q1_s = q1v_cap ? q1_cap : 16'sd0;

    // Wet branch: q is scaled by q_ramp/256. Before the first valid history the
    // branch is exactly 0 (y=(x+0)>>1, frozen contract); when q becomes valid it
    // ramps in over 256 frames so there is no step at n=D.
    wire signed [24:0] q_scaled = $signed(q0_s) * $signed({1'b0, q_ramp});
    wire signed [15:0] q_eff    = q_scaled >>> 8;
    wire signed [16:0] sum_active = $signed(x_cap) + $signed(q_eff);
    wire signed [15:0] wet_active = sum_active >>> 1;

    wire signed [24:0] xf_mix = ($signed(q0_s) * $signed({1'b0, (8'd255 - xf_idx)})) +
                                ($signed(q1_s) * $signed({1'b0, xf_idx}));
    wire signed [15:0] wet_xf = xf_mix >>> 8;

    wire signed [15:0] wet_sel = (state == S_CROSSFADE) ? wet_xf : wet_active;

    // gain is 0..256 inclusive; multiply by the 9-bit value (256 must not wrap)
    wire signed [24:0] blend = ($signed(x_cap) * $signed({1'b0, (9'd256 - gain)})) +
                               ($signed(wet_sel) * $signed({1'b0, gain}));
    wire signed [15:0] mixed = blend >>> 8;

    reg signed [15:0] mixed_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mixed_q <= 16'sd0;
        else if (!frame_tick && slot == MIX_SLOT + 1) mixed_q <= mixed;
    end

    assign sample_out = (state == S_OFF) ? $signed(sample_in) : mixed_q;

    always @(*) begin
        dbg_state = {5'd0, state};
        dbg_gain  = {7'd0, gain};
    end

endmodule
