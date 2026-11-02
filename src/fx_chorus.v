// ============================================================================
// fx_chorus -- bypassable mono chorus (W20-T3, GW5AT-60B / Tang Mega 60K)
// ============================================================================
// Work order : task/task-2 (W20-T3), tree F:/fiehuo/w20_glide_20261029.
// Style reference: rtl/fx_delay.v (bypassable delay line: same frame_tick,
// single-BSRAM, history-counter and combinational-bypass conventions) and
// rtl/fx_reverb.v (same pipeline-comment style).  Self-contained module: no
// wave shaper, no ROM, one multiplier, one 18 Kbit BSRAM, no feedback.
//
// Signal path (enable = 1)
//
//   x[n] --+--> [ 1024 x 16 circular RAM ] --(2 synchronous reads)--> x0, x1
//          |                                                         |
//          |                        mu from the LFO fraction <--------+
//          |                             |
//          |                      wet = x0 + mu*(x1-x0)        (1 DSP)
//          |                             |
//          +---------------------> mix (dry, wet) --> sat16 --> sample_out
//
//   x[n] -----------------------------------------------------> sample_out (enable = 0)
//
// Fixed-point contract (work order W20-T3)
//   f_s      = 48828.125 Hz, one frame_tick pulse per sample (1024 clk frame)
//   delay(n) = CENTER + mod(n)   samples,  CENTER = 732 (15 ms)
//   mod      in [-73.000, +72.988] samples (peak +-1.5 ms), triangle LFO
//   phase    = 16 bit, +1 per frame -> period 65536 frames = 1.342 s = 0.745 Hz
//   linear interpolation with an 8-bit fraction (mu) taken from the same LFO:
//       delay_q8 = 659*256 + modsum                   (Q8 samples)
//       d_int    = delay_q8[17:8]                     integer delay, 659..804
//       mu       = delay_q8[7:0]                      Q0.8 interpolation fraction
//       wet      = x0 + ((mu * (x1 - x0)) >>> 8)
//   The ">>> 8" is an ARITHMETIC (floor) shift; it is the only rounding in the
//   wet path.  Exactly one "*" in this file -> one 18x18 DSP.
//
// LFO: no ROM, no multiplier
//   tri16  = phase[15] ? ~phase : phase        0 .. 65535, period 65536 frames
//   modsum = (tri16>>1) + (tri16>>4) + (tri16>>7)
//          = floor(tri16 * 37376 / 65536) - 0..2 LSB,     37376 = 2*73*256
//   Two adds instead of a multiplier.  delay_q8 spans [168704, 206077], i.e.
//   delay = [659.000, 804.988] samples = 732 +- 73 to within 1/256 of a
//   sample.  NOTE: the +73 endpoint is 0.012 sample short because tri16 tops
//   out at 65535 (not 65536) and the shift/add form truncates; the modulation
//   depth is 145.99 of the specified 146 samples.  This is the only numerical
//   deviation from the "732 +- 73" wording and it is < 1/256 sample.
//
// Delay-line organisation
//   One circular buffer of DEPTH = 1024 slots x 16 bit (16 Kbit -> exactly one
//   18 Kbit BSRAM).  The largest read distance is 805 slots (d_int <= 804 plus
//   the one-frame-older interpolation tap), so a read address can never equal
//   the write address (>= 219 slots apart) and no read-hazard exists.  The one
//   read port is TIME-MULTIPLEXED twice per frame, at two different clk slots
//   (never a dual-read-port / true-dual-port RAM variant):
//       read #1 -> x0 at addr0     = wptr - d_int
//       read #2 -> x1 at addr0 - 1 (one frame OLDER -> delay d_int + mu)
//   x0 is therefore the tap at integer delay d_int and x1 at d_int+1, so the
//   interpolated tap sits at fractional delay d_int + mu/256.
//
// Timing (delivery frame = 1024 clk; the whole frame is available, the module
// only needs the first 16 clk after the boundary.  The directed TB also runs
// the identical logic on a 32-clk accelerated frame.)
//   clk#0     : frame_tick (frame boundary).  pt8211_i2s_tx latches the
//               previous frame's sample_out at this same edge, so y[n] must be
//               stable well before it.
//   clk#1..#9 : tick_sr fill.  sample_in is only guaranteed valid from clk#9
//               after frame_tick (interface contract), hence capture at #10.
//   clk#10    : capture -- latch addr0 / mu / mix_sel / hist_ok / dry_q,
//               advance the 16-bit LFO phase, issue RAM read #1.
//   clk#11    : issue RAM read #2 (addr0 - 1); RAM output register = x0
//   clk#12    : x0_q <= x0
//   clk#13    : x1_q <= x1
//   clk#14    : prod_q <= (mu * (x1 - x0)) >>> 8          (the DSP)
//   clk#15    : wet gating + dry/wet mix + sat16 -> y_out; write-back of x[n]
//               at the pre-advance wptr, wptr/hist advance
//   y[n] is stable from clk#15 on, i.e. ~1009 clk before the next clk#0, so
//   the module adds ZERO audio frames of latency.  Only the wet tap is delayed
//   (15 ms is the effect itself); the dry part of the mix is the SAME frame's
//   sample, so dry and wet stay frame-aligned with the rest of the chain.
//
// Bypass / enable discipline (same contract as fx_delay / fx_reverb)
//   enable = 0 is a PURE COMBINATIONAL mux: sample_out === sample_in, bit
//   exact, zero registers in the path, zero frames of latency.  The delay line
//   and the LFO keep advancing while bypassed (the wet value is still computed
//   and the dry sample still written), so a mid-stream enable flip is
//   glitch-free and the chorus history is already warm.
//
// History / reset
//   BSRAM is NOT reset address by address (1024 words would burn a
//   configuration pass for nothing; Gowin configuration zeroes BSRAM anyway).
//   `hist` counts the samples written since reset and saturates at
//   FULL_MIN = CENTER + MOD_HALF + 1 = 732 + 73 + 1 = 806, and the wet
//   contribution is forced to 0 until then.
//   WHY 806: the two taps are d_int (<= 804) and d_int+1 (<= 805), so 806
//   written samples guarantee that BOTH taps hold real data for every LFO
//   phase.  Before that the wet path is muxed to zero, so the un-written
//   (X in simulation) RAM slots can never reach the mixer or the output.
//   The DRY path is not gated: during the fill-in out = mix(dry, 0), which is
//   exactly the mix contract with a silent wet input.
//
// Mix
//   mix_sel = 0 : out = sat16( (3*dry + wet) >>> 2 )    3/4 dry, 1/4 wet
//   mix_sel = 1 : out = sat16( (dry + wet) >>> 1 )      1/2 dry, 1/2 wet
//   Both are weight-by-shift adds (no extra DSP).  The three-way sum peaks at
//   3*32767 + 32767 = 131068 and the wet is a genuine interpolated sample
//   (|wet| <= 32767), so a 19-bit signed intermediate is exact and sat16 is a
//   formality kept as the module's saturation contract.  mix_sel is sampled
//   together with the dry sample, so the setting valid when x[n] entered the
//   module is the one that mixes y[n].
//
// Resource intent
//   1 x 18 Kbit BSRAM (1024 x 16), 1 DSP (one 18x18 multiplier), ~143 FF in
//   fabric plus the 53 RAM port flops that Gowin folds into the BSRAM
//   (rd_addr / rd_data / wr_en / wr_addr / wr_data), no ROM, no feedback term.
// ============================================================================

`default_nettype none

module fx_chorus (
    input  wire        clk,
    input  wire        rst_n,       // async, active low (same as top level)
    input  wire        frame_tick,  // 1-clk pulse at Fs = 48828.125 Hz
    input  wire [15:0] sample_in,   // signed 16-bit, valid from clk#9
    input  wire        enable,      // 0 = bit-exact combinational bypass
    input  wire        mix_sel,     // 0 = 3/4 dry : 1/4 wet, 1 = 1/2 : 1/2
    output wire [15:0] sample_out   // signed 16-bit
);

    // ------------------------------------------------------------------------
    // Geometry and fixed-point constants (W20-T3; not runtime-tunable)
    // ------------------------------------------------------------------------
    localparam integer ADDR_W   = 10;                       // 1024 slots
    localparam integer DEPTH    = 1024;                     // one 18 Kbit BSRAM
    localparam integer CENTER   = 732;                      // 15 ms @ 48.828125 kHz
    localparam integer MOD_HALF = 73;                       // +-1.5 ms
    localparam integer FULL_MIN = CENTER + MOD_HALF + 1;    // 806 = 733 + 73

    // Q8 delay of the minimum tap: 659*256 = 168704 (expressed as a shift so
    // that the ONLY "*" operator in this file is the interpolation multiply).
    localparam [18:0] DELAY_MIN_Q8 = ((CENTER - MOD_HALF) <<< 8);

    // Sized constants.  DEPTH itself needs ADDR_W+1 bits (1024 does not fit in
    // 10 bits), so the wrap arithmetic below runs on ADDR_W+1 bits.
    localparam [ADDR_W:0]   DEPTH_A     = DEPTH;
    localparam [ADDR_W-1:0] DEPTH_M1_A  = DEPTH - 1;
    localparam [ADDR_W-1:0] FULL_MIN_A  = FULL_MIN;
    localparam [ADDR_W-1:0] ZERO_A      = {ADDR_W{1'b0}};

    // Symmetric 16-bit saturation to [-32767, +32767] (the -32768 code is
    // deliberately never produced -- same clamp contract as fx_delay).
    function signed [15:0] sat16;
        input signed [18:0] v;
        begin
            if (v > 19'sd32767)
                sat16 = 16'sd32767;
            else if (v < -19'sd32767)
                sat16 = -16'sd32767;
            else
                sat16 = v[15:0];
        end
    endfunction

    // ========================================================================
    // Triangle LFO: 16-bit phase, +1 per frame, zero ROM / zero multiplier
    // ========================================================================
    reg  [15:0] phase;
    // FOLD + DOUBLE (fixed 2026-10-30): folding a 16-bit phase gives only
    // 0..32767, so tri16 alone spans HALF the documented 0..65535 range.  That
    // made the modulation one-sided and half depth: tb_chorus_full measured
    // d_int = 659..731 (spec 659..804), mean delay 695.5 samples = 14.24 ms
    // (spec 732 = 15 ms), modulation [-73.000 .. -0.012] instead of
    // [-73.000 .. +72.988].  Doubling restores the full swing; the LFO period
    // stays 65536 frames (0.745 Hz) because the phase rate is unchanged.
    wire [15:0] tri16  = phase[15] ? (~phase) : phase;      // 0..32767 triangle
    wire [16:0] tri17  = {tri16, 1'b0};                     // 0..65534 full swing
    // (tri17 * 37376) >> 16 == (tri17>>1) + (tri17>>4) + (tri17>>7) up to 2 LSB
    // of the Q8 word; 37376 = 2*MOD_HALF*256 = 2^15 + 2^12 + 2^9.
    wire [16:0] modsum = (tri17 >> 1)
                       + (tri17 >> 4)
                       + (tri17 >> 7);

    wire [18:0]       delay_q8 = DELAY_MIN_Q8 + {2'b00, modsum};  // 168704..206077
    wire [ADDR_W-1:0] d_int    = delay_q8[17:8];                  // 659..804
    wire [7:0]        mu       = delay_q8[7:0];                   // Q0.8 fraction

    // ========================================================================
    // Circular delay line: one synchronous read port, one write port
    // ========================================================================
    (* syn_ramstyle = "block_ram" *) reg [15:0] mem [0:DEPTH-1];

    reg  [ADDR_W-1:0] rd_addr;      // registered read address (RAM port)
    reg  [15:0]       rd_data;      // synchronous read data (RAM output reg)
    reg               wr_en;        // registered write enable (RAM port)
    reg  [ADDR_W-1:0] wr_addr;      // registered write address
    reg  [15:0]       wr_data;      // registered write data

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // Write pointer / history counter.  hist saturates at FULL_MIN (only the
    // wet gate consumes it; see the header).
    reg  [ADDR_W-1:0] wptr;
    reg  [ADDR_W-1:0] hist;
    wire              hist_ok_w = (hist >= FULL_MIN_A);
    wire [ADDR_W-1:0] wptr_next = (wptr == DEPTH_M1_A) ? ZERO_A : (wptr + 1'b1);

    // Read address #1 = (wptr - d_int) mod DEPTH.  d_int and wptr are both
    // < DEPTH, so {wptr + (DEPTH - d_int)} < 2*DEPTH and one conditional
    // subtract wraps it (same idiom as fx_delay).
    wire [ADDR_W:0] rd_off  = DEPTH_A - {1'b0, d_int};
    wire [ADDR_W:0] rd_sum  = {1'b0, wptr} + rd_off;
    wire [ADDR_W:0] rd_wrap = rd_sum - DEPTH_A;
    wire [ADDR_W-1:0] addr0_w = (rd_sum >= DEPTH_A) ? rd_wrap[ADDR_W-1:0]
                                                    : rd_sum[ADDR_W-1:0];

    // ========================================================================
    // Pipeline: capture -> 2 RAM reads -> interpolate -> mix/saturate
    // ========================================================================
    reg [9:0] tick_sr;      // frame_tick delay chain; [9] = capture slot (clk#10)
    reg [4:0] vsr;          // stage valid: [0] 2nd read, [1] x0, [2] x1,
                            //              [3] product, [4] mix + write-back

    reg signed [15:0] dry_q;      // x[n] for the frame being processed
    reg        [7:0]  mu_q;       // interpolation fraction of that frame
    reg               mix_q;      // mix_sel of that frame
    reg               hist_ok_q;  // wet gate of that frame
    reg signed [15:0] x0_q;       // tap at integer delay d_int
    reg signed [15:0] x1_q;       // tap at delay d_int + 1
    reg signed [17:0] prod_q;     // ((mu * (x1-x0)) >>> 8), 18 bit
    reg signed [15:0] y_out;      // wet/dry mix register (held one frame)

    // ---- stage 3: interpolation product (the only multiplier in the file) --
    // |mu*(x1-x0)| <= 255*65534 = 16,711,170 < 2^24, so the 25-bit product is
    // exact; >>> 8 lands in +-65279 and fits the 18-bit product register.
    wire signed [16:0] diff_w = x1_q - x0_q;                    // +-65535
    wire signed [24:0] prod_w = $signed({1'b0, mu_q}) * diff_w; // 1 DSP
    wire signed [17:0] prod_sh = prod_w >>> 8;

    // ---- stage 4: gated wet sum -------------------------------------------
    // hist_ok_q is captured with the frame, so an unwritten slot can never
    // reach the mixer (header "History / reset").
    wire signed [17:0] wet_sum  = {{2{x0_q[15]}}, x0_q} + prod_q;
    wire signed [17:0] wet_used = hist_ok_q ? wet_sum : 18'sd0;

    // ---- stage 5: dry/wet mix + sat16 -------------------------------------
    // 19-bit signed intermediates: |3*dry + wet| <= 131068 < 2^17, exact.
    wire signed [18:0] dry_m  = {{3{dry_q[15]}}, dry_q};
    wire signed [18:0] wet_m  = {{1{wet_used[17]}}, wet_used};
    wire signed [18:0] mix3_w = (((dry_m <<< 1) + dry_m) + wet_m) >>> 2;
    wire signed [18:0] mix2_w = (dry_m + wet_m) >>> 1;
    wire signed [18:0] mix_w  = mix_q ? mix2_w : mix3_w;
    wire signed [15:0] out_w  = sat16(mix_w);

    // ---- read-only probe points (directed TB / debug; no logic cost) ------
    wire cap_slot = tick_sr[9];     // capture slot  (frame_tick + 10 clk)
    wire rd1_slot = vsr[0];         // issue of RAM read #2
    wire rd2_slot = vsr[1];         // x0 register update

    // ========================================================================
    // Main sequential process (async active-low reset, no latch)
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase     <= 16'd0;
            wptr      <= ZERO_A;
            hist      <= ZERO_A;
            rd_addr   <= ZERO_A;
            // NOTE (W20 integration, 2026-10-29): the line that reset rd_data here
            // was REMOVED. rd_data is the synchronous RAM output register and is
            // driven by the dedicated read-port always block above; a second
            // driver made Gowin synthesis fail with
            //   ERROR (EX2000): Net 'rd_data[15]' is constantly driven from
            //   multiple places  (fx_chorus.v:189 / :319)
            // ModelSim tolerated the race, Gowin does not. The read port has no
            // reset by design (same style as fx_delay/fx_reverb), and rd_data is
            // only consumed once hist has filled (wet gate), so this is safe.
            wr_en     <= 1'b0;
            wr_addr   <= ZERO_A;
            wr_data   <= 16'd0;
            tick_sr   <= 10'd0;
            vsr       <= 5'd0;
            dry_q     <= 16'sd0;
            mu_q      <= 8'd0;
            mix_q     <= 1'b0;
            hist_ok_q <= 1'b0;
            x0_q      <= 16'sd0;
            x1_q      <= 16'sd0;
            prod_q    <= 18'sd0;
            y_out     <= 16'sd0;
        end else begin
            tick_sr <= {tick_sr[8:0], frame_tick};
            vsr     <= {vsr[3:0], tick_sr[9]};
            wr_en   <= 1'b0;

            // ---- capture (clk#10): metadata of x[n] + RAM read #1 ----------
            if (tick_sr[9]) begin
                rd_addr   <= addr0_w;
                dry_q     <= $signed(sample_in);
                mu_q      <= mu;
                mix_q     <= mix_sel;
                hist_ok_q <= hist_ok_w;
                phase     <= phase + 16'd1;
            end

            // ---- clk#11: issue RAM read #2, one frame older -----------------
            if (vsr[0])
                rd_addr <= rd_addr - 1'b1;

            // ---- clk#12: x0 valid ------------------------------------------
            if (vsr[1])
                x0_q <= $signed(rd_data);

            // ---- clk#13: x1 valid ------------------------------------------
            if (vsr[2])
                x1_q <= $signed(rd_data);

            // ---- clk#14: interpolation product -----------------------------
            if (vsr[3])
                prod_q <= prod_sh;

            // ---- clk#15: mix/saturate output + delay-line write-back -------
            if (vsr[4]) begin
                y_out   <= out_w;
                wr_en   <= 1'b1;
                wr_addr <= wptr;            // slot of x[n] (pre-advance)
                wr_data <= dry_q;
                wptr    <= wptr_next;
                if (hist != FULL_MIN_A)
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
