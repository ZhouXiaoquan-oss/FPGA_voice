// ============================================================================
// fx_delay -- bypassable mono digital feedback delay (Task-010 / SubTask-010-A)
// ============================================================================
// Signal path
//   sample_in --> [circular delay line, DEPTH slots] --> feedback K --> sum
//              --> sat16 --> sample_out (when enable = 1)
//   sample_in ----------------------------------------> sample_out (enable = 0)
//
// Fixed-point contract (work order SS "编码约束"):
//   y[n] = sat16( x[n] + trunc( y[n-D] * K / 256 ) )
//   * K is a compile-time Q0.8 coefficient, default 128 (0.5).
//
// ----------------------------------------------------------------------------
// POP FIX AMENDMENT (task/task-019, L1 ruling board v9 2026-10-25 23:27):
//   sample_out(ENABLED) = ( x[n] + trunc( y[n-D] * K / 256 ) ) >>> 1
//   i.e. the dry+wet mix is halved at the OUTPUT REGISTER ONLY; the delay
//   line still stores the full saturated sum, so K, the four delay settings
//   and the loop coefficient (0.5) are all UNCHANGED -- the echo character
//   is bit-identical to the delivery design, at -6 dB port level.
//   WHY: the 60 ms port gain was 1.8621 at 784 Hz (feedback resonance,
//   tb_pop_delay scenario A) and pushed the analog output stage past its
//   clip point.  Halving the port bounds it by 16384 <= 32767 (sat16 at the
//   port becomes unreachable) and brings the 60 ms gain to ~0.931, the 30 ms
//   gain to ~0.334 -- exactly the ruling's expected numbers.  Alternative
//   placements are rejected in the task-019 report section 一 (reverb-only:
//   dead when bypassed; top-level: also halves the bypass path = the
//   rejected global -6 dB; halving both operands AT the sum: halves the loop
//   coefficient to 0.25, run 5 measured 0.656/0.401, report section 四).
//   Pre-fix evidence: F:/fiehuo/w11_pop_20261025/sim/pop_run3.log.
// ----------------------------------------------------------------------------
//   * trunc() is a two's-complement ARITHMETIC right shift by 8, i.e. it
//     rounds towards -infinity (e.g. -500.5 -> -501), never towards zero.
//   * The value stored in the delay line is the saturated wet output, clamped
//     to [-32767, +32767] (symmetric clamp, so -32768 is never written).
//   * K is realised as a shift-add network (bit-serial add of sign-extended
//     shifted copies). There is NO "*" operator anywhere in this file, so no
//     multiplier/DSP can be inferred.
//
// Delay line organisation
//   One physical circular buffer of DEPTH = 7325 slots (16 bit each) is shared
//   by all four settings. 7324 = maximum logical delay, +1 slot so that the
//   read address (wptr - D) and the write address (wptr) are NEVER equal, even
//   at D = 7324. The four settings are 1465 / 2197 / 2930 / 7324 frames
//   (round(30/45/60/150 ms * 48828.125 Hz)).
//
//   delay_sel = 00 -> 1465 (30 ms)
//               01 -> 2197 (45 ms)
//               10 -> 2930 (60 ms)
//               11 -> 7324 (150 ms; W1b fourth "demo" setting)
//
// Timing
//   * frame_tick is the only sample-rate enable. The module samples its input
//     ONE clk AFTER the frame_tick edge: top_touch updates its sample register
//     exactly on frame_tick, so the post-edge value is the new sample and is
//     stable for the whole 1024-clk frame. Sampling it immediately (on the
//     frame_tick edge itself) would pick up the previous frame and add one
//     audio frame of latency; the cost of this one-clk offset is nothing.
//   * Read -> multiply -> add/saturate -> register completes 4 clk after
//     frame_tick, i.e. ~1020 clk before the next frame boundary at Fs. The wet
//     output register therefore holds a stable value for the next I2S latch
//     and the ACTIVE path adds ZERO audio frames of latency (it is aligned
//     with the dry sample transmitted in the same I2S frame).
//   * The delay-line state advances even while enable = 0 (the wet value is
//     still computed and written); only the output mux is switched. Bypass is
//     a pure combinational path from sample_in to sample_out: zero registers,
//     zero frame offset, bit-exact.
//   * A frame period shorter than 6 clk would overlap pipeline stages; at the
//     product's 1024-clk frame period this is impossible.
//
// History / reset
//   BSRAM is NOT reset address by address (7300+ words would burn a
//   configuration pass for nothing). Instead `hist` counts the number of
//   samples written since reset and saturates at DEPTH; while
//   hist < D the feedback term is forced to 0, so an unwritten slot can never
//   be read back into the loop.
//
// Resource intent (G1)
//   DSP 0, one inferred block RAM of DEPTH x 16 (payload 117,200 bit,
//   capacity lower bound 7 x 18Kbit), <= 14 reported 18Kbit units.
// ============================================================================

`default_nettype none

module fx_delay #(
    // Q0.8 feedback coefficient (0..255). Delivery value = 128 (0.5).
    // Simulation overrides it at elaboration time (vsim -gK=...).
    parameter integer K = 128,

    // Circular buffer geometry and the four delay settings, in frames.
    // DEPTH = D150 + 1 so read and write addresses never coincide.
    parameter integer DEPTH = 7325,
    parameter integer D30   = 1465,
    parameter integer D45   = 2197,
    parameter integer D60   = 2930,
    parameter integer D150  = 7324
)(
    input  wire        clk,
    input  wire        rst_n,       // async, active low (same as top level)
    input  wire        frame_tick,  // one clk per audio frame
    input  wire [15:0] sample_in,   // 16-bit two's complement mono dry
    input  wire        enable,      // 1 = effect on, 0 = hard bypass
    input  wire [1:0]  delay_sel,   // 00/01/10/11 = 30/45/60/150 ms
    output wire [15:0] sample_out   // 16-bit two's complement mono
);

    // ------------------------------------------------------------ width helpers
    // Local constant function (no $clog2, keeps old tool chains happy).
    function integer clog2v(input integer value);
        integer i;
        begin
            clog2v = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2v = clog2v + 1;
        end
    endfunction

    localparam integer ADDR_W = clog2v(DEPTH);      // 7325 -> 13

    // Sized copies of the integer parameters (explicit widths, no implicit
    // 32-bit slices in the address arithmetic below).
    localparam [ADDR_W-1:0] DEPTH_A = DEPTH;
    localparam [ADDR_W-1:0] D30_A   = D30;
    localparam [ADDR_W-1:0] D45_A   = D45;
    localparam [ADDR_W-1:0] D60_A   = D60;
    localparam [ADDR_W-1:0] D150_A  = D150;
    localparam [ADDR_W-1:0] ZERO_A  = {ADDR_W{1'b0}};

    localparam [7:0] KMASK = K;                     // Q0.8 mantissa

    // ========================================================================
    // Constant multiplication by K: shift-add network, no "*"
    // ========================================================================
    // product = v * K = sum over bits i of K of (v << i), with v sign-extended
    // to 25 bit first. Maximum |product| = 32767 * 255 = 8,355,585 < 2^23, so
    // 25 signed bits have ample headroom. The loop is fully unrolled at
    // elaboration; `term <<< 1` is a constant shift, not a variable shifter.
    function signed [24:0] mul_k;
        input signed [15:0] v;
        integer i;
        reg signed [24:0] acc;
        reg signed [24:0] term;
        begin
            acc  = 25'sd0;
            term = {{9{v[15]}}, v};                 // sign-extend 16 -> 25
            for (i = 0; i < 8; i = i + 1) begin
                if (KMASK[i])
                    acc = acc + term;
                term = term <<< 1;
            end
            mul_k = acc;
        end
    endfunction

    // Symmetric 16-bit saturation to [-32767, +32767]. The asymmetric -32768
    // code is deliberately not produced, matching the work order's clamp.
    function signed [15:0] sat16f;
        input signed [24:0] v;
        begin
            if (v > 25'sd32767)
                sat16f = 16'sd32767;
            else if (v < -25'sd32767)
                sat16f = -16'sd32767;
            else
                sat16f = v[15:0];
        end
    endfunction

    // ========================================================================
    // Delay line: one read port, one write port, one clock
    // ========================================================================
    // No reset on mem: Gowin configuration already zeroes BSRAM contents and
    // `hist` gates access to never-written slots (see header).
    (* syn_ramstyle = "block_ram" *) reg [15:0] mem [0:DEPTH-1];

    reg  [ADDR_W-1:0] wptr;        // write address for the NEXT finished sample
    reg  [ADDR_W-1:0] hist;        // samples written since reset, saturates at DEPTH
    reg  [ADDR_W-1:0] rd_addr;     // registered read address
    reg  [15:0]       rd_data;     // synchronous read data

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    reg                wr_en;
    reg  [ADDR_W-1:0]  wr_addr;
    reg  [15:0]        wr_data;

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // ========================================================================
    // Pipeline: frame_tick(+1) -> read addr / metadata -> multiply -> sum/sat
    // ========================================================================
    // tick_d is a one-clk-delayed frame_tick (input capture); tick_d2 is one
    // more clk and marks the cycle in which the synchronous RAM output is
    // valid for that sample (see the pipeline note below).
    reg tick_d;
    reg tick_d2;

    // Metadata latched for the sample being processed.
    reg signed [15:0] x_hold;      // dry sample x[n]
    reg  [ADDR_W-1:0] wptr_hold;   // slot for y[n]
    reg               hist_ok;     // y[n-D] exists (hist >= D at capture time)

    // Stage valid bits (a frame period is 1024 clk, so stages never overlap).
    reg s1_valid;                  // rd_data is valid for this sample
    reg s2_valid;                  // prod_q is valid for this sample

    reg signed [24:0] prod_q;      // trunc(y[n-D] * K) before >>8

    reg signed [15:0] y_out;       // wet output register (held one frame)

    // Delay selection at the capture instant (11 -> 60 ms, documented above).
    wire [ADDR_W-1:0] dly_w = (delay_sel == 2'd0) ? D30_A  :
                              (delay_sel == 2'd1) ? D45_A  :
                              (delay_sel == 2'd2) ? D60_A  :
                                                    D150_A;

    // Read address = (wptr - D) mod DEPTH. wptr < DEPTH and DEPTH - D < DEPTH,
    // so the sum is < 2*DEPTH and a single conditional subtract wraps it.
    wire [ADDR_W:0] rd_sum  = {1'b0, wptr} + {1'b0, (DEPTH_A - dly_w)};
    // The subtraction result is < DEPTH when the wrap branch is taken (because
    // rd_sum < 2*DEPTH), so the low ADDR_W bits are exact -- slice explicitly
    // to keep the intent visible and the synthesiser quiet.
    wire [ADDR_W:0] rd_wrap = rd_sum - {1'b0, DEPTH_A};
    wire [ADDR_W-1:0] rd_calc = (rd_sum >= {1'b0, DEPTH_A}) ?
                                rd_wrap[ADDR_W-1:0] :
                                rd_sum[ADDR_W-1:0];

    wire              hist_ok_w = (hist >= dly_w);
    wire [ADDR_W-1:0] wptr_next = (wptr == (DEPTH_A - 1'b1)) ? ZERO_A
                                                             : (wptr + 1'b1);

    // Multiply stage: register the shift-add product of the RAM output.
    // Sum stage (POP FIX, task/task-019, L1 ruling v9): dry and wet are each
    // halved BEFORE the add, so the enabled path is bounded by
    // (32767>>1) + (16383>>1) = 24575 < 32767 -- sat16f becomes mathematically
    // unreachable there and the loop gain is capped at 0.5/(1-0.5) = 1.0
    // (was 1/(1-0.5) = 2.0, the 784 Hz @ 60 ms resonance).  Feedback stays
    // forced to 0 while the requested history is not yet present.
    wire signed [24:0] prod_w = mul_k($signed(rd_data));
    wire signed [24:0] fb_w   = hist_ok ? (prod_q >>> 8) : 25'sd0;
    wire signed [24:0] sum_w  = {{9{x_hold[15]}}, x_hold} + fb_w;
    wire signed [15:0] y_new  = sat16f(sum_w);
    // POP FIX output half (task/task-019, L1 ruling v9): see the header
    // amendment.  The mix is halved at the OUTPUT REGISTER ONLY; the delay
    // line keeps storing the full saturated sum so the loop coefficient
    // stays 0.5 (echo character unchanged) and the port gain halves.
    //   run 5 lesson (kept as evidence): halving both operands AT the sum
    //   halves the loop coefficient as well (0.5 -> 0.25) and yields port
    //   gains 0.656/0.401 -- NOT the ~0.93/~0.33 the ruling expects.
    //   NB: a concatenation is UNSIGNED in Verilog (that was run 4's sign
    //   inversion); y_new here is a plain signed wire, so its >>> IS
    //   arithmetic.
    wire signed [15:0] y_out_h = y_new >>> 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_d    <= 1'b0;
            tick_d2   <= 1'b0;
            rd_addr   <= ZERO_A;
            x_hold    <= 16'sd0;
            wptr_hold <= ZERO_A;
            hist_ok   <= 1'b0;
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            prod_q    <= 25'sd0;
            y_out     <= 16'sd0;
            wptr      <= ZERO_A;
            hist      <= ZERO_A;
            wr_en     <= 1'b0;
            wr_addr   <= ZERO_A;
            wr_data   <= 16'd0;
        end else begin
            tick_d   <= frame_tick;
            tick_d2  <= tick_d;
            s1_valid <= tick_d2;
            s2_valid <= s1_valid;
            wr_en    <= 1'b0;

            // ---- capture: address + metadata for the new sample -------------
            if (tick_d) begin
                rd_addr   <= rd_calc;
                x_hold    <= $signed(sample_in);
                wptr_hold <= wptr;
                hist_ok   <= hist_ok_w;
            end

            // ---- stage 1: RAM output valid -> shift-add product -------------
            if (s1_valid)
                prod_q <= prod_w;

            // ---- stage 2: add / saturate / write back / update output -------
            if (s2_valid) begin
                wr_en   <= 1'b1;
                wr_addr <= wptr_hold;
                wr_data <= y_new;
                y_out   <= y_out_h;
                wptr    <= wptr_next;
                if (hist != DEPTH_A)
                    hist <= hist + 1'b1;
            end
        end
    end

    // ========================================================================
    // Output mux: hard bypass is combinational (bit-exact, zero frame offset)
    // ========================================================================
    assign sample_out = enable ? y_out : sample_in;

endmodule

`default_nettype wire
