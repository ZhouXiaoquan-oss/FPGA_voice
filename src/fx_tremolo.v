// ============================================================================
// fx_tremolo -- bypassable mono amplitude modulation (tremolo)
// ============================================================================
// W20-T2.  Single 50 MHz clock domain, one sample per frame_tick
// (Fs = 48828.125 Hz, 1024 clk per frame).  This module is INDEPENDENT of the
// existing pitch vibrato: it only scales the sample, it never changes phase.
//
// Signal path
//   sample_in --> [x_r @ clk#10] --> x * gain_q10 >> 10 --> sat16 --> [y_r @ clk#11]
//              --> sample_out                      (when depth_sel != 0)
//   sample_in --------------------------------------> sample_out  (depth_sel == 0)
//
// Fixed-point contract
//   u_q16   = lfo_samp + 32768                    -> [0, 65535] unsigned
//   depth   = 0 / 128 / 256 / 512 (Q10) for depth_sel = 0/1/2/3
//   gain    = 1024 - ((depth * u_q16) >>> 16)     -> Q10, 1024 = 1.0
//   y       = sat16( (x * gain) >>> 10 ), x = sample_in latched for this frame
//
//   * depth_sel == 0 is a PURE COMBINATIONAL bypass: sample_out = sample_in at
//     bit level, zero registers, zero frame offset.  It does not even look at
//     the audio pipeline (the pipeline keeps running, but its result is not
//     selected).
//   * ">>>" is an arithmetic right shift, i.e. rounding towards -infinity, so
//     the reference model in the TB is floor(x*gain/1024), not a round().
//   * sat16 is the symmetric clamp [-32767, +32767].  The asymmetric -32768
//     code is never produced by the enabled path.
//
// Why u_q16 is an XOR: for 16-bit two's complement, (x + 32768) mod 65536 is
// exactly a toggle of the sign bit, so the +32768 offset costs one XOR gate
// per bit -- no adder, no carry chain.
//
// Why there is only ONE multiplier: depth is a power of two (128/256/512), so
// (depth * u_q16) >>> 16 collapses to a constant right shift of the 16-bit
// unsigned LFO (u >> 9, u >> 8, u >> 7 respectively).  The whole file contains
// exactly one "*" (the 16 x 12 audio product), which is the single DSP.
//
// Timing (frame_tick = 1 clk pulse; ~1024 clk of budget per frame)
//   cnt counts clk from the frame_tick edge.  sample_in is valid from clk#9
//   after frame_tick in the top level, so:
//     clk#10 : x_r  <= sample_in            (audio sample latched)
//     clk#11 : y_r  <= sat16(x_r*gain >>> 10)
//   Both events finish at clk#11, ~1013 clk before the next frame boundary and
//   far before the I2S latch point, so the enabled path adds ZERO audio frames
//   of latency: y_r holds this frame's result for the rest of this frame.
//   A 4-bit counter is enough because it saturates at 15 and the real frame is
//   1024 clk; a frame shorter than 12 clk would break the pipeline (it is
//   never shorter than 1024 clk in this product).
//   The LFO input is assumed frame-stable (the shared DDS updates it once per
//   frame), so the multiply reads the same LFO value the capture stage saw.
//
// Resource intent
//   FF  : cnt[3:0] + x_r[15:0] + y_r[15:0] = 36
//   DSP : 1   (the single "*")
//   RAM : 0   LUT : shifts/mux/compare only, no new wave table
//
// Reset
//   Asynchronous, active low, on every flip-flop.  1024 clk (one frame) after
//   reset release the pipeline is full; until then y_r is simply 0.
// ============================================================================

`default_nettype none

module fx_tremolo #(
    // Capture slot, counted in clk after the frame_tick edge. Default 10 is the
    // standalone contract (sample_in valid from clk#9). When this module is
    // chained AFTER one whose result registers later (fx_chorus lands at clk#15),
    // pass that module's output slot + 1 so the capture still takes THIS frame.
    parameter integer CAP_SLOT = 10
)(
    input  wire        clk,
    input  wire        rst_n,           // async, active low
    input  wire        frame_tick,      // 1-clk pulse at Fs = 48828.125 Hz
    input  wire [15:0] sample_in,       // signed 16-bit audio, valid from clk#9
    input  wire [1:0]  depth_sel,       // 0=off/bypass 1=1/8 2=1/4 3=1/2
    input  wire signed [15:0] lfo_samp, // shared 5.5006 Hz sine, +-32767
    output wire [15:0] sample_out       // signed 16-bit
);

    // ========================================================================
    // LFO mapping and Q10 gain
    // ========================================================================
    // u_q16 = lfo_samp + 32768, realized as a sign-bit toggle (see header).
    // -32767 -> 1, 0 -> 32768, +32767 -> 65535.
    wire [15:0] u_q16 = lfo_samp ^ 16'h8000;

    // term_q10 = (depth * u_q16) >>> 16 with depth = 2^S (S = 7/8/9).
    // The product is (u << S); shifting it right by 16 is u >>> (16-S).
    // All three cases are constant shifts on the unsigned 16-bit value.
    //   depth_sel 1 -> 128 = 2^7 -> u >> 9   (max 127, fits 7 bit)
    //   depth_sel 2 -> 256 = 2^8 -> u >> 8   (max 255, fits 8 bit)
    //   depth_sel 3 -> 512 = 2^9 -> u >> 7   (max 511, fits 9 bit)
    //   depth_sel 0 -> 0      -> 0           (bypassed anyway)
    wire [15:0] term_q10 = (depth_sel == 2'd1) ? {7'd0, u_q16[15:9]} :
                           (depth_sel == 2'd2) ? {8'd0, u_q16[15:8]} :
                           (depth_sel == 2'd3) ? {9'd0, u_q16[15:7]} :
                                                 16'd0;

    // gain_q10 = 1024 - term.  Delivery depths give 897 (7/8), 769 (3/4),
    // 513 (1/2) at the LFO peak (u = 65535) and 1024 (1.0) at the LFO trough
    // (u = 1) -- i.e. attenuation only, never a boost above unity.
    wire [10:0] gain_q10 = 11'd1024 - {1'b0, term_q10[9:0]};

    // ========================================================================
    // Frame-relative pipeline: capture at clk#10, output register at clk#11
    // ========================================================================
    reg [4:0] cnt;          // clk count since frame_tick, saturates at 31
    localparam [4:0] CAP0 = CAP_SLOT[4:0];

    reg signed [15:0] x_r;  // audio sample of the current frame
    reg signed [15:0] y_r;  // processed sample of the current frame

    // The only multiplier in this file (1 DSP).  x is 16 bit signed, gain is
    // 0..1024 (12 bit signed via zero extension); |product| <= 2^25, so the
    // 27-bit signed result has one spare bit for the following shift.
    wire signed [26:0] prod_w = x_r * $signed({1'b0, gain_q10});

    // Symmetric 16-bit saturation: clamp to [-32767, +32767].
    function signed [15:0] sat16;
        input signed [26:0] v;
        begin
            if (v > 27'sd32767)
                sat16 = 16'sd32767;
            else if (v < -27'sd32767)
                sat16 = -16'sd32767;
            else
                sat16 = v[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 5'd0;
            x_r <= 16'sd0;
            y_r <= 16'sd0;
        end else if (frame_tick) begin
            // Start of a new frame: restart the in-frame pipeline counter.
            cnt <= 5'd0;
        end else begin
            if (cnt != 5'd31)
                cnt <= cnt + 5'd1;
            if (cnt == CAP0)
                x_r <= $signed(sample_in);          // capture slot (default clk#10)
            if (cnt == (CAP0 + 5'd1))
                y_r <= sat16(prod_w >>> 10);        // output register slot + 1
        end
    end

    // ========================================================================
    // Output mux: bypass is combinational and bit-exact (zero frame offset)
    // ========================================================================
    assign sample_out = (depth_sel == 2'd0) ? sample_in : y_r;

endmodule

`default_nettype wire
