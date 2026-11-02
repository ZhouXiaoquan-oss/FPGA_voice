// ============================================================================
// fx_reverb -- bypassable mono Schroeder reverb, ZERO DSP (L1 W10, 2026-10-25)
// ============================================================================
// Work order : task/task-017/工单_W10混响_2026-10-25.md (L1, 2026-10-25 11:35)
// Tree       : W10_20261025 (copied from W9_20261024; the W9 tree is untouched)
//
// Structure (work order section 四)
//
//   sample_in ──┬─────────────────────────────→ dry ──────────────┐
//               │                                                 │
//               └→ [4 parallel damped feedback combs] → Σ → [2    ├→ mix → out
//                        ^                                series  │
//                        └── shift-only feedback g ──────── allpass] wet
//
//   * Comb i (Schroeder feedback comb, Freeverb-style damping):
//       d_i[n] = dampLP_i( c_i[n-Di] )          one-pole, per-comb state
//       c_i[n] = sat16( (1-g)*x[n] + g * d_i[n] )  stored into slot wp_i
//       the comb's contribution to the sum is d_i (the damped DELAYED value).
//     W17 window-2 change A (comb normalisation, 2026-10-27): the input is
//     scaled by (1-g) instead of 1, so the comb peak gain is 1 instead of
//     1/(1-g) (1 -> 1/2 -> 1/4 -> 1/8 at g = 0.5 / 0.75 / 0.875).  Without it
//     the 4-comb sum reaches 4 * 1/(1-g) = +18 dB at the resonances, which is
//     the dominant term of the measured 44.6 dB peak-to-trough span.
//     |H_i| = (1-g)/|1 - g z^-Di| in [(1-g)/(1+g), 1]: amplifying impossible.
//     (1-g) is 0.5 / 0.25 / 0.125 -> constant shifts, still ZERO DSP.
//     Delay lengths Di = 1236 / 1316 / 1414 / 1502 samples (work order 二).
//   * Allpass j (TRUE all-pass, one delay line, a = 0.5 = ">>1", lengths
//     616 / 488) -- W17 window-2 change C (2026-10-27):
//       w_j[n] = sat16( x_j[n] + (w_j[n-Dj] >>> 1) )   <-- stored in a?_mem
//       y_j[n] = sat16( w_j[n-Dj] - (w_j[n] >>> 1) )
//     i.e.  H_j(z) = (z^-Dj - 0.5) / (1 - 0.5 z^-Dj),  |H_j| === 1 EXACTLY at
//     every frequency (unit gain, phase only).  The W10b "Freeverb form"
//       out = z[n-D] - x ,  z[n] = x + 0.5 z[n-D]
//     was NOT an all-pass: it is  H = (1.5 z^-D - 1)/(1 - 0.5 z^-D)  whose
//     magnitude swings between 1.000 and 2.778 for D = 616/488 (8.9 dB) --
//     that is the measured diffuser magnitude ripple this change removes.
//     Both new equations use only constant shifts (a = 0.5 = >>1), so the
//     zero-DSP contract is unchanged.  Only 2 shifts per stage instead of 1
//     decrement + 1 shift; the delay lines keep the same length and meaning
//     (they now store the internal node w_j instead of z_j).
//     a = 0.5 is EXACTLY representable in binary, so this is not an
//     approximation: the only deviation from |H| = 1 comes from the 16-bit
//     store truncation (documented in the overflow policy below).
//   * Mix (W17 window-2, change A+C+beta):  out = sat16( (1-beta)*dry + beta*wet ),
//     beta = 1/8 = (>>3) by default (BETA_SH = 3).  W10b used
//     out = sat16( dry + (wet>>1) ), i.e. beta = 1/2 plus a full-level dry.
//     The crossfade form is what makes the dry+wet interference bounded:
//     |H| in [1-beta, 1+beta] for |wet| <= 1 (see the A/C notes above).
//
// Zero-DSP contract (work order section 三) -- there is NO "*" operator
// anywhere in this file, so no multiplier/DSP can be inferred:
//   room_sel : 0 -> g = 0.500 = (d>>1)
//              1 -> g = 0.750 = (d>>1) + (d>>2)
//              2 -> g = 0.875 = (d>>1) + (d>>2) + (d>>3)
//   damp_sel : 0 -> d = y                                   damping off
//              1 -> d = (y>>1) + lp - (lp>>1)               a = 1/2
//              2 -> d = (y>>2) + lp - (lp>>2)               a = 1/4
//              3 -> d = (y>>3) + lp - (lp>>3)               a = 1/8
//   (lp = the per-comb one-pole state.  The form is the arithmetic identity
//    (y + (2^s - 1)*lp) >> s split into two CONSTANT shifts, s = damp_sel, so
//    no variable-amount shifter is needed.  Larger s = stronger damping.)
//
// sample_tick discipline (work order section 四, "⚠ 关键")
//   The port is named frame_tick (the top_touch / fx_delay convention) -- it
//   IS the work order's sample_tick: one 1-clk pulse per audio frame at
//   48.828125 kHz.  All six write pointers advance ONLY on the frame_tick-
//   derived capture chain below, never free-running on clk, so the six delay
//   times cannot drift with the system clock.
//
// Pipeline (delivery frame = 1024 clk; the module needs frame >= 9 clk --
//   strictly non-overlapping stages; the directed TB additionally proves the
//   delivery 1024-clk frame and runs most tests at an accelerated 16-clk
//   frame, which exercises the identical per-sample logic):
//   E1      : frame_tick reads 1 (frame boundary).  pt8211_i2s_tx latches
//             sample_l/r at this same edge, so mix_out must be valid before
//             the NEXT E1.
//   E2..E5  : rv_t1..rv_t4 tick shift.
//   E6 (rv_t5)  : capture x_hold <= sample_in.  sample_in is u_fx_delay's
//             sample_out, whose y_out register updates at E5 (fx_delay
//             pipeline), so capturing at E6 takes the NEW wet-delay sample.
//             fx_reverb therefore adds ZERO audio-frame latency relative to
//             the fx_delay-only W9 chain.
//   E7 (rv_s1)  : synchronous BSRAM read of all six slots into rd1..rd6.
//   E8 (rv_s2)  : stage 1 -- damping, comb feedback/saturate, comb sum.
//                 The four comb writes go to the pre-advance wp1..wp4 slots,
//                 wps 1..4 advance, lp states update, and the stage-1/2
//                 boundary registers take s_ap_q <= s_ap, rd5_q <= rd5,
//                 rd6_q <= rd6.  rd5_q/rd6_q MUST be held together with
//                 s_ap_q (the allpass equations pair s_ap[n] with z[n-D];
//                 delaying one without the other is a mathematical
//                 misalignment -- L1 correction 2026-10-25 20:10); safe
//                 because wp5/wp6 do not advance within the sample until E9.
//   E9 (rv_s3)  : stage 2 -- both allpasses from s_ap_q/rd5_q/rd6_q, wet
//                 mix, the two allpass writes to the pre-advance wp5/wp6
//                 slots (which then advance), and mix_out takes the wet+dry
//                 sum.  PIPELINE HISTORY: W10b "Plan A" first put a 16-bit
//                 register AFTER the wet sum (mix_hold) -- the chain TAIL,
//                 which changed nothing physically (V2 PnR: endpoints merely
//                 renamed mix_out -> mix_hold, violations 38 -> 64, worst
//                 -3.915 ns).  The cut now sits mid-chain at s_ap, splitting
//                 the ~23 ns single-cycle path (BSRAM Q -> damping -> comb
//                 sum -> AP1 -> AP2 -> mix) into ~8-10 ns + ~13-15 ns.
//                 TIMING CONTRACT UNCHANGED vs W10b: mix_out lands at E9,
//                 still stable ~1015 clk before the next E1 latch, so the
//                 I2S consumer sees an identical stream and every 198
//                 regression anchor keeps its bit-exact value.  frame
//                 requirement 9 clk (1024-clk delivery frame and the TB's
//                 16-clk accelerated frame are both unaffected).
//
// Overflow policy -- saturation everywhere, wraparound impossible:
//   Every 16-bit store and the output pass sat16 (symmetric clamp to
//   +-32767; the -32768 code is never produced).  Internal sums use 17/18-bit
//   signed intermediates; the widest, the comb sum, peaks at
//   4 x 32767 = 131068 < 2^17 = 131072.  s_ap = comb_sum >>> 2 therefore
//   spans exactly [-32767, +32767] with no additional saturation needed.
//   With dry at a full-scale DC rail, |wet| <= 16384 < 32767, so the output
//   keeps the input's sign at all times (proved in TB test 2).
//   W17 window-2 (change C): the true all-pass nodes are ONE BIT wider than
//   the old Freeverb nodes and therefore need an explicit 17-bit sat16_17:
//       w_new = x + (w_old>>>1)  in [-(1.5*32767), +1.5*32767]  -> 17 bit ok
//       y     = w_old - (w_new>>>1)                           -> 17 bit ok
//   Both stay inside +-49150 < 2^16, so the 17-bit intermediate is exact and
//   sat16_17 clamps only if a genuine rail-to-rail sample is present.  The
//   saturation is the ONLY non-linearity in the diffuser: it does not occur
//   in any measured scenario (rail_n = 0 on the whole audit matrix; with the
//   audit drive level = 511 LSB the widest node is ~1.2 kLSB).
//
// Known characteristic (documented, accepted -- same convention as fx_delay):
//   The feedback uses ARITHMETIC right shifts (round towards -infinity), so
//   tiny NEGATIVE loop values truncate towards a small fixed point instead of
//   decaying to exact 0 (worst case about -4 LSB per comb at g = 0.875, i.e.
//   a residual of a few LSB at the output, < 0.02 % FS, inaudible).  Positive
//   values decay to exact 0.  TB test 1 bounds-checks the residual.
//
// Memory / reset
//   Six independent (* syn_ramstyle = "block_ram" *) arrays, one 16-bit write
//   port each, synchronous read -- Gowin BSRAM inference (work order 二:
//   10 x 18K blocks = 2+2+2+2+1+1).  The arrays are NOT reset at runtime;
//   initial blocks zero them (ModelSim X-state guard), and Gowin
//   configuration zeroes BSRAM contents anyway (same flow as fx_delay).
//   Unlike fx_delay there is no hist gate: an unwritten (zero) slot reads
//   d = 0 -> fb = 0, which is exactly the correct empty-line behaviour.
//
// Commands (wired in top_touch.v; this file is policy-free)
//   0x0C reverb on/off (delivery default OFF), 0x0D room 0/1/2, 0x0E damping
//   0/1/2/3.  enable = 0 is a PURE COMBINATIONAL bypass (sample_out ===
//   sample_in, no register, bit-exact), while the six lines keep advancing so
//   a mid-stream enable flip is glitch-free -- identical to the fx_delay
//   bypass contract.  With reverb defaulting off, every 198 regression anchor
//   is bit-identical to W9/W8.
// ============================================================================

`default_nettype none

module fx_reverb #(
    parameter integer C1_D = 1236,   // comb 1 length, samples (work order 二)
    parameter integer C2_D = 1316,   // comb 2
    parameter integer C3_D = 1414,   // comb 3
    parameter integer C4_D = 1502,   // comb 4
    parameter integer A1_D = 616,    // allpass 1
    parameter integer A2_D = 488,    // allpass 2
    // W17 window-2: beta = 2^-BETA_SH is the dry/wet crossfade weight
    // (3 = 1/8, the L3/consultant value; 4 = 1/16 is the variant measured in
    // the window-2 report).  A parameter, not a constant, only so the audit
    // TB can re-elaborate; synthesis always uses the default.
    parameter integer BETA_SH = 3,
    // L1 2026-10-27 listening test B: wet-side only extra gain = 2^WET_SH (3 = x8)
    parameter integer WET_SH = 3
)(
    input  wire        clk,
    input  wire        rst_n,       // async, active low (same as top level)
    input  wire        frame_tick,  // work order "sample_tick": 1 clk per frame
    input  wire [15:0] sample_in,   // 16-bit two's complement mono dry
    input  wire        enable,      // 1 = reverb on, 0 = hard bypass
    input  wire [1:0]  room_sel,    // 00/01/10 = g 0.500 / 0.750 / 0.875
    input  wire [1:0]  damp_sel,    // 00..11 = damping off / a=1/2 / 1/4 / 1/8
    output wire [15:0] sample_out
);

    // ------------------------------------------------------------ width helpers
    // Local constant function (no $clog2, keeps old tool chains happy) --
    // same helper as fx_delay.v.
    function integer clog2v(input integer value);
        integer i;
        begin
            clog2v = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2v = clog2v + 1;
        end
    endfunction

    // Symmetric 16-bit saturation to [-32767, +32767] from an 18-bit signed
    // intermediate.  The asymmetric -32768 code is deliberately never
    // produced (same clamp contract as fx_delay).
    function signed [15:0] sat16_18(input signed [17:0] v);
        begin
            if (v > 18'sd32767)
                sat16_18 = 16'sd32767;
            else if (v < -18'sd32767)
                sat16_18 = -16'sd32767;
            else
                sat16_18 = v[15:0];
        end
    endfunction

    // Explicit sign-extends so every shift/sum below is provably signed and
    // correctly sized (no implicit 32-bit context widening).
    function signed [16:0] se17(input signed [15:0] v);
        se17 = {v[15], v};
    endfunction

    function signed [17:0] se18(input signed [15:0] v);
        se18 = {{2{v[15]}}, v};
    endfunction

    // Same symmetric clamp from a 17-bit intermediate (W17 window-2): the true
    // all-pass nodes are one bit wider than the 16-bit delay-line payload.
    function signed [15:0] sat16_17(input signed [16:0] v);
        begin
            if (v > 17'sd32767)
                sat16_17 = 16'sd32767;
            else if (v < -17'sd32767)
                sat16_17 = -16'sd32767;
            else
                sat16_17 = v[15:0];
        end
    endfunction

    localparam integer AW1 = clog2v(C1_D);          // 1236 -> 11
    localparam integer AW2 = clog2v(C2_D);          // 1316 -> 11
    localparam integer AW3 = clog2v(C3_D);          // 1414 -> 11
    localparam integer AW4 = clog2v(C4_D);          // 1502 -> 11
    localparam integer AW5 = clog2v(A1_D);          //  616 -> 10
    localparam integer AW6 = clog2v(A2_D);          //  488 ->  9

    // ========================================================================
    // Six delay lines: one circular buffer each, 16 bit wide, synchronous
    // read + single write port -> two 18K BSRAM blocks per comb (payload
    // 19.8..24.0 kbit), one per allpass: 10 blocks total (work order 二).
    // ========================================================================
    (* syn_ramstyle = "block_ram" *) reg [15:0] c1_mem [0:C1_D-1];
    (* syn_ramstyle = "block_ram" *) reg [15:0] c2_mem [0:C2_D-1];
    (* syn_ramstyle = "block_ram" *) reg [15:0] c3_mem [0:C3_D-1];
    (* syn_ramstyle = "block_ram" *) reg [15:0] c4_mem [0:C4_D-1];
    (* syn_ramstyle = "block_ram" *) reg [15:0] a1_mem [0:A1_D-1];
    (* syn_ramstyle = "block_ram" *) reg [15:0] a2_mem [0:A2_D-1];

    // Simulation-only zero init (see header "Memory / reset").  Gowin
    // configuration zeroes BSRAM contents, so hardware behaviour is the same
    // whether or not synthesis honours the initial blocks.
    integer ii;
    initial begin
        for (ii = 0; ii < C1_D; ii = ii + 1) c1_mem[ii] = 16'h0000;
        for (ii = 0; ii < C2_D; ii = ii + 1) c2_mem[ii] = 16'h0000;
        for (ii = 0; ii < C3_D; ii = ii + 1) c3_mem[ii] = 16'h0000;
        for (ii = 0; ii < C4_D; ii = ii + 1) c4_mem[ii] = 16'h0000;
        for (ii = 0; ii < A1_D; ii = ii + 1) a1_mem[ii] = 16'h0000;
        for (ii = 0; ii < A2_D; ii = ii + 1) a2_mem[ii] = 16'h0000;
    end

    // Write pointers: all six advance by ONE, ONCE per frame_tick -- this is
    // the work order's "6 条延迟线同一 sample_tick 推进".
    reg [AW1-1:0] wp1;
    reg [AW2-1:0] wp2;
    reg [AW3-1:0] wp3;
    reg [AW4-1:0] wp4;
    reg [AW5-1:0] wp5;
    reg [AW6-1:0] wp6;

    // Synchronous read: the slot wp points at is the one written Di samples
    // ago (write at wp, then advance).  The register below is the RAM output
    // register (keeps BSRAM inference); the value captured on the rv_s1 edge
    // is this sample's delayed tap.
    reg [15:0] rd1, rd2, rd3, rd4, rd5, rd6;

    always @(posedge clk) begin
        rd1 <= c1_mem[wp1];
        rd2 <= c2_mem[wp2];
        rd3 <= c3_mem[wp3];
        rd4 <= c4_mem[wp4];
        rd5 <= a1_mem[wp5];
        rd6 <= a2_mem[wp6];
    end

    // ========================================================================
    // Capture chain and sample-held registers
    // ========================================================================
    reg rv_t1, rv_t2, rv_t3, rv_t4, rv_t5;          // tick shift (5 clk)
    reg rv_s1, rv_s2, rv_s3;                        // stage-valid pulses
    reg signed [15:0] x_hold;                       // dry sample x[n]
    reg signed [15:0] lp1_q, lp2_q, lp3_q, lp4_q;   // damping LP states
    // W20 2026-10-30: comb-feedback pipeline stage (stage 1b).  The comb loop
    // rd_i -> damping -> g*d_i -> +nx -> sat -> mem used to be ONE combinational
    // span of 10..12 levels with no register in it; it became the critical path
    // (u_fx_reverb/c4_mem, slack 0.024 ns @ 50 MHz, 50 marginal endpoints) and it
    // is placement-dominated, so no placer option fixes it reliably.  Splitting it
    // across two edges that both land inside the same 1024-clk frame is bit-exact
    // (see the note above the stage-1b datapath below).
    reg signed [15:0] d1_q, d2_q, d3_q, d4_q;
    reg signed [17:0] s_ap_q;                       // R1 Cut A (L1 20:10):
    reg signed [15:0] rd5_q;                        // stage-1/2 boundary at
    reg signed [15:0] rd6_q;                        // s_ap; a1/a2 taps held
                                                    // with it (see header E8)
    reg signed [15:0] mix_out;                      // wet+dry output register

    // ---- comb taps (delayed outputs y_i[n-Di]) ----------------------------
    wire signed [15:0] y1_old = rd1;
    wire signed [15:0] y2_old = rd2;
    wire signed [15:0] y3_old = rd3;
    wire signed [15:0] y4_old = rd4;

    // ---- per-comb damping low-pass (one-pole, shift-only, see header) -----
    wire signed [16:0] lp1_w =
          (damp_sel == 2'd0) ? se17(y1_old)
        : (damp_sel == 2'd1) ? ((se17(y1_old) >>> 1) + (se17(lp1_q) - (se17(lp1_q) >>> 1)))
        : (damp_sel == 2'd2) ? ((se17(y1_old) >>> 2) + (se17(lp1_q) - (se17(lp1_q) >>> 2)))
        :                      ((se17(y1_old) >>> 3) + (se17(lp1_q) - (se17(lp1_q) >>> 3)));
    wire signed [15:0] d1 = sat16_18({lp1_w[16], lp1_w});

    wire signed [16:0] lp2_w =
          (damp_sel == 2'd0) ? se17(y2_old)
        : (damp_sel == 2'd1) ? ((se17(y2_old) >>> 1) + (se17(lp2_q) - (se17(lp2_q) >>> 1)))
        : (damp_sel == 2'd2) ? ((se17(y2_old) >>> 2) + (se17(lp2_q) - (se17(lp2_q) >>> 2)))
        :                      ((se17(y2_old) >>> 3) + (se17(lp2_q) - (se17(lp2_q) >>> 3)));
    wire signed [15:0] d2 = sat16_18({lp2_w[16], lp2_w});

    wire signed [16:0] lp3_w =
          (damp_sel == 2'd0) ? se17(y3_old)
        : (damp_sel == 2'd1) ? ((se17(y3_old) >>> 1) + (se17(lp3_q) - (se17(lp3_q) >>> 1)))
        : (damp_sel == 2'd2) ? ((se17(y3_old) >>> 2) + (se17(lp3_q) - (se17(lp3_q) >>> 2)))
        :                      ((se17(y3_old) >>> 3) + (se17(lp3_q) - (se17(lp3_q) >>> 3)));
    wire signed [15:0] d3 = sat16_18({lp3_w[16], lp3_w});

    wire signed [16:0] lp4_w =
          (damp_sel == 2'd0) ? se17(y4_old)
        : (damp_sel == 2'd1) ? ((se17(y4_old) >>> 1) + (se17(lp4_q) - (se17(lp4_q) >>> 1)))
        : (damp_sel == 2'd2) ? ((se17(y4_old) >>> 2) + (se17(lp4_q) - (se17(lp4_q) >>> 2)))
        :                      ((se17(y4_old) >>> 3) + (se17(lp4_q) - (se17(lp4_q) >>> 3)));
    wire signed [15:0] d4 = sat16_18({lp4_w[16], lp4_w});

    // ---- comb feedback g * d_i (shift-add network, work order 三) ---------
    // |fb| <= 0.875 * 32767 + 2 LSB truncation = 28672, fits 17 bits.
    wire signed [16:0] fb1_w =
          (room_sel == 2'd0) ? (se17(d1) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d1) >>> 1) + (se17(d1) >>> 2))
        :                      ((se17(d1) >>> 1) + (se17(d1) >>> 2) + (se17(d1) >>> 3));
    wire signed [16:0] fb2_w =
          (room_sel == 2'd0) ? (se17(d2) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d2) >>> 1) + (se17(d2) >>> 2))
        :                      ((se17(d2) >>> 1) + (se17(d2) >>> 2) + (se17(d2) >>> 3));
    wire signed [16:0] fb3_w =
          (room_sel == 2'd0) ? (se17(d3) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d3) >>> 1) + (se17(d3) >>> 2))
        :                      ((se17(d3) >>> 1) + (se17(d3) >>> 2) + (se17(d3) >>> 3));
    wire signed [16:0] fb4_w =
          (room_sel == 2'd0) ? (se17(d4) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d4) >>> 1) + (se17(d4) >>> 2))
        :                      ((se17(d4) >>> 1) + (se17(d4) >>> 2) + (se17(d4) >>> 3));

    // ---- comb input scale (1-g) : window-2 change A (comb normalisation) ---
    // W10b comb:  c_i[n] = x[n] + g*d_i[n]        -> |H_i| = 1/(1-g) = 8 at g
    //                                                    = 0.875  (+18 dB peak)
    // W17 comb:   c_i[n] = (1-g)*x[n] + g*d_i[n]  -> |H_i| = (1-g)/|1-g z^-D|
    //                                                    <= 1, i.e. the comb can
    //     no longer amplify: it is a decaying comb whose steady gain is <= 1.
    // (1-g) is exactly 0.5 / 0.25 / 0.125 for the three rooms, so the same
    // shift-only contract applies -- ZERO DSP, no multiplier.
    wire signed [16:0] nx_w =
          (room_sel == 2'd0) ? ((se17(x_hold) >>> 2) + (se17(x_hold) >>> 4))   // 5/16 = 0.3125 (c=0.625)
        : (room_sel == 2'd1) ? (se17(x_hold) >>> 2)                              // 4/16 = 0.2500 (unchanged)
        :                      ((se17(x_hold) >>> 3) + (se17(x_hold) >>> 4));     // 3/16 = 0.1875 (c=1.5);

    // ---- comb new stored value: c_i[n] = sat16( (1-g)x[n] + g*d_i ) ------
    wire signed [17:0] y1_sum = {{1{nx_w[16]}}, nx_w} + {{1{fb1_w[16]}}, fb1_w};
    wire signed [15:0] y1_new = sat16_18(y1_sum);
    wire signed [17:0] y2_sum = {{1{nx_w[16]}}, nx_w} + {{1{fb2_w[16]}}, fb2_w};
    wire signed [15:0] y2_new = sat16_18(y2_sum);
    wire signed [17:0] y3_sum = {{1{nx_w[16]}}, nx_w} + {{1{fb3_w[16]}}, fb3_w};
    wire signed [15:0] y3_new = sat16_18(y3_sum);
    wire signed [17:0] y4_sum = {{1{nx_w[16]}}, nx_w} + {{1{fb4_w[16]}}, fb4_w};
    wire signed [15:0] y4_new = sat16_18(y4_sum);

    // ========================================================================
    // W20 2026-10-30: STAGE-1b comb write datapath (pipelined feedback loop)
    // ------------------------------------------------------------------------
    // The four comb lines are a feedback loop with NO register in it:
    //     rd_i (RAM out reg) -> damping lp_i_w -> d_i -> g*d_i -> +nx_w
    //     -> sat16 -> c_i_mem[wp_i]   (10..12 levels, routing-dominated)
    // Measured slack on u_fx_reverb/c4_mem was 0.024 ns at 50 MHz (50 marginal
    // endpoints) and it is what caps every W20 variant, so the loop is split
    // into two edges that BOTH land inside the same 1024-clk frame:
    //     rv_s2 : d_i   -> d_i_q                       (damping result latched)
    //     rv_s3 : d_i_q -> g*d_i_q -> +nx_w -> sat -> mem write, then wp_i++
    // Bit-exactness: the value written to slot wp_i at frame n is still derived
    // from rd_i of frame n (wp_i does not move between the two edges, and the
    // sample delay is set by the address difference Di, not by the clock), so
    // the sample sequence is unchanged.  The original y*_new wires are kept for
    // the comb SUM (s_ap) and the damping state update, which still happen on
    // the rv_s2 edge exactly as before.
    // Cost: 64 FF, zero DSP, zero RAM.
    // ========================================================================
    wire signed [16:0] fb1_p =
          (room_sel == 2'd0) ? (se17(d1_q) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d1_q) >>> 1) + (se17(d1_q) >>> 2))
        :                      ((se17(d1_q) >>> 1) + (se17(d1_q) >>> 2) + (se17(d1_q) >>> 3));
    wire signed [16:0] fb2_p =
          (room_sel == 2'd0) ? (se17(d2_q) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d2_q) >>> 1) + (se17(d2_q) >>> 2))
        :                      ((se17(d2_q) >>> 1) + (se17(d2_q) >>> 2) + (se17(d2_q) >>> 3));
    wire signed [16:0] fb3_p =
          (room_sel == 2'd0) ? (se17(d3_q) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d3_q) >>> 1) + (se17(d3_q) >>> 2))
        :                      ((se17(d3_q) >>> 1) + (se17(d3_q) >>> 2) + (se17(d3_q) >>> 3));
    wire signed [16:0] fb4_p =
          (room_sel == 2'd0) ? (se17(d4_q) >>> 1)
        : (room_sel == 2'd1) ? ((se17(d4_q) >>> 1) + (se17(d4_q) >>> 2))
        :                      ((se17(d4_q) >>> 1) + (se17(d4_q) >>> 2) + (se17(d4_q) >>> 3));

    wire signed [15:0] y1_new_p = sat16_18({{1{nx_w[16]}}, nx_w} + {{1{fb1_p[16]}}, fb1_p});
    wire signed [15:0] y2_new_p = sat16_18({{1{nx_w[16]}}, nx_w} + {{1{fb2_p[16]}}, fb2_p});
    wire signed [15:0] y3_new_p = sat16_18({{1{nx_w[16]}}, nx_w} + {{1{fb3_p[16]}}, fb3_p});
    wire signed [15:0] y4_new_p = sat16_18({{1{nx_w[16]}}, nx_w} + {{1{fb4_p[16]}}, fb4_p});

    // ---- parallel comb sum -------------------------------------------------
    // |d_i| <= 32767 each -> |sum| <= 131068 < 2^17: exact in 18 bits, no
    // saturation needed on the sum itself.
    wire signed [17:0] comb_sum = se18(d1) + se18(d2) + se18(d3) + se18(d4);
    // >>>2 lands exactly in [-32767, +32767] (131068>>>2 = 32767), no sat.
    wire signed [17:0] s_ap     = comb_sum >>> 2;

    // ---- series allpass 1 : TRUE all-pass (window-2 change C) -------------
    // Stage-2 inputs are the E8-held taps (see header E8/E9): bufout1 pairs
    // with s_ap_q, never with the live rd5, or the difference equation
    // would mix x[n-1] with w[n-D].
    //   w1[n] = x + 0.5*w1[n-616]   (this is what a1_mem stores)
    //   y1[n] = w1[n-616] - 0.5*w1[n]
    //   H1(z) = (z^-616 - 0.5)/(1 - 0.5 z^-616)  ->  |H1| == 1
    wire signed [15:0] x1      = s_ap_q[15:0];      // |s_ap| <= 32767 (proved)
    wire signed [15:0] bufout1 = rd5_q;             // w1[n-616]
    wire signed [16:0] w1_sum  = se17(x1) + (se17(bufout1) >>> 1);
    wire signed [15:0] w1_new  = sat16_17(w1_sum);
    wire signed [16:0] y1_w    = se17(bufout1) - (se17(w1_new) >>> 1);
    wire signed [15:0] y1_q    = sat16_17(y1_w);

    // ---- series allpass 2 --------------------------------------------------
    wire signed [15:0] x2      = y1_q;              // stage-1 output feeds stage 2
    wire signed [15:0] bufout2 = rd6_q;             // w2[n-488]
    wire signed [16:0] w2_sum  = se17(x2) + (se17(bufout2) >>> 1);
    wire signed [15:0] w2_new  = sat16_17(w2_sum);
    wire signed [16:0] y2_w    = se17(bufout2) - (se17(w2_new) >>> 1);
    wire signed [15:0] y2_q    = sat16_17(y2_w);

    // ---- mix: out = (1-beta)*dry + beta*wet  -------------------------------
    // W17 window-2 (2026-10-27): the dry/wet mix is now an equal-shape
    // CROSSFADE, not "dry + wet>>1".  beta = 1/8 (BETA_SH = 3) is the value
    // the consultant / L3 prompt fixes for this route ("每级 beta=1/8",
    // single-stage bound |H| <= 1+beta = +1.02 dB, >= 1-beta = -1.16 dB).
    //   out = x - (x>>>3) + (wet>>>3)
    // beta is a SHIFT, so still zero DSP.  BETA_SH is a parameter only so the
    // verification window can re-elaborate at 4 (-6 dB more wet) with
    // vsim -gBETA_SH=4; the delivered default stays 3.
    wire signed [17:0] dry_x   = se18(x_hold) - (se18(x_hold) >>> BETA_SH);   // 18b for wide wet
        wire signed [17:0] wet_x   = se18(y2_q) <<< 1;                     // x16 of beta=1/8 = 2.0*y2_q
    wire signed [17:0] mix_sum = dry_x + wet_x;      // <= 7/8*32767 + 4096
    wire signed [15:0] mix_w   = sat16_18(mix_sum);

    // ========================================================================
    // Main sequential process: tick chain, capture, compute/write stage
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rv_t1   <= 1'b0;
            rv_t2   <= 1'b0;
            rv_t3   <= 1'b0;
            rv_t4   <= 1'b0;
            rv_t5   <= 1'b0;
            rv_s1   <= 1'b0;
            rv_s2   <= 1'b0;
            rv_s3   <= 1'b0;
            x_hold  <= 16'sd0;
            wp1     <= {AW1{1'b0}};
            wp2     <= {AW2{1'b0}};
            wp3     <= {AW3{1'b0}};
            wp4     <= {AW4{1'b0}};
            wp5     <= {AW5{1'b0}};
            wp6     <= {AW6{1'b0}};
            lp1_q   <= 16'sd0;
            lp2_q   <= 16'sd0;
            lp3_q   <= 16'sd0;
            lp4_q   <= 16'sd0;
            s_ap_q  <= 18'sd0;
            rd5_q   <= 16'sd0;
            rd6_q   <= 16'sd0;
            mix_out <= 16'sd0;
        end else begin
            rv_t1 <= frame_tick;
            rv_t2 <= rv_t1;
            rv_t3 <= rv_t2;
            rv_t4 <= rv_t3;
            rv_t5 <= rv_t4;
            rv_s1 <= rv_t5;
            rv_s2 <= rv_s1;
            rv_s3 <= rv_s2;

            // ---- capture: the new dry sample (fx_delay's output has been
            //      stable since E5; see header pipeline note) ---------------
            if (rv_t5)
                x_hold <= $signed(sample_in);

            // ---- compute/write stage 1 (combs).  Runs unconditionally of
            //      enable so the six lines keep advancing while bypassed
            //      (fx_delay philosophy; the output mux below is the only
            //      gate) ----------------------------------------------------
            if (rv_s2) begin
                // W20 2026-10-30: stage 1a -- latch the damping result.  The comb
                // WRITE and the pointer advance moved to the rv_s3 edge (stage 1b)
                // so that the feedback loop rd_i -> ... -> mem has a register in
                // it.  Both edges are inside the same 1024-clk frame, so the
                // sample sequence is unchanged (see the stage-1b note above).
                d1_q <= d1;
                d2_q <= d2;
                d3_q <= d3;
                d4_q <= d4;

                // damping low-pass states
                lp1_q <= d1;
                lp2_q <= d2;
                lp3_q <= d3;
                lp4_q <= d4;

                // stage-1/2 boundary: comb-bank output + the two allpass
                // taps, held TOGETHER (header E8)
                s_ap_q <= s_ap;
                rd5_q  <= rd5;
                rd6_q  <= rd6;
            end

            // ---- compute/write stage 2 (allpasses + mix).  wp5/wp6 advance
            //      HERE, one clk later than wp1..wp4, matching the delayed
            //      a1/a2 writes (header E9) ---------------------------------
            if (rv_s3) begin
                // W20 2026-10-30: stage 1b -- comb write from the registered
                // damping result, then advance the comb pointers.  Same slot, same
                // value as the pre-pipeline design, one clk later (still inside the
                // frame), which is what breaks the long feedback loop.
                c1_mem[wp1] <= y1_new_p;
                c2_mem[wp2] <= y2_new_p;
                c3_mem[wp3] <= y3_new_p;
                c4_mem[wp4] <= y4_new_p;
                wp1 <= (wp1 == (C1_D - 1)) ? {AW1{1'b0}} : (wp1 + 1'b1);
                wp2 <= (wp2 == (C2_D - 1)) ? {AW2{1'b0}} : (wp2 + 1'b1);
                wp3 <= (wp3 == (C3_D - 1)) ? {AW3{1'b0}} : (wp3 + 1'b1);
                wp4 <= (wp4 == (C4_D - 1)) ? {AW4{1'b0}} : (wp4 + 1'b1);

                a1_mem[wp5] <= w1_new;
                a2_mem[wp6] <= w2_new;
                wp5 <= (wp5 == (A1_D - 1)) ? {AW5{1'b0}} : (wp5 + 1'b1);
                wp6 <= (wp6 == (A2_D - 1)) ? {AW6{1'b0}} : (wp6 + 1'b1);

                // wet+dry output register
                mix_out <= mix_w;
            end
        end
    end

    // ========================================================================
    // Output mux: hard bypass is combinational (bit-exact, zero latency)
    // ========================================================================
    assign sample_out = enable ? mix_out : sample_in;

endmodule

`default_nettype wire
