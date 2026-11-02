`define TS_MUX
// ============================================================================
// W20 FEATURE SWITCHES (2026-10-30 round) -- the ONLY place build variants differ.
// ----------------------------------------------------------------------------
// `set_option -verilog_define` is SILENTLY IGNORED by gw_sh V1.9.11 Education
// (proven in the W8 round: F:/fiehuo/w8_tsmux_20261024/build_pnr.tcl), so the
// variant is selected by editing these lines. build_variant_w20.ps1 rewrites
// exactly them and refuses to run if any of them is missing or duplicated.
//
//   min    : TS_MUX                     -> delivered F1 + tremolo baseline
//   chorus : TS_MUX + W20_CHORUS        -> adds 0x11 toggle / 0x12 dry-wet
//   glide  : TS_MUX + W20_GLIDE         -> adds 0x0F 4-level portamento
//   full   : TS_MUX + W20_CHORUS + W20_GLIDE
//
// Each feature is wrapped in `ifdef so that switching it OFF removes the whole
// block (no residue). Tremolo is always compiled in (it is the delivered win).
// ============================================================================
`define W20_CHORUS
`define W20_GLIDE
// ============================================================================
// top_touch -- Tang Mega 60K (GW5AT-60B) N-voice polyphonic synthesizer
// ============================================================================
// p6_touch (SubTask-004-A): SubTask-003-A's 15-key synth with the MPR121
// capacitive-touch chain actually INTEGRATED. The 15 note keys fed to
// keys_note_ctl are no longer 15 raw pins; they are the concatenation
//
//     key_bus[14:0] = {key[2:0], ~touch_hi[11:0]}
//                      --------  -----------------
//                      |         +-- touch_lo[11:0]: the 12 MPR121 electrodes
//                      |             ELE0..ELE11, inverted to LOW active
//                      +-- the three onboard keys AA13 / AB13 / Y12, already
//                          LOW active (internal pull-up, pressed = GND)
//
// mpr121.touch is HIGH active, so the 12 electrodes are inverted bit by bit and
// concatenated BELOW the onboard keys. The result is one uniformly LOW-active
// bus: keys_note_ctl (and therefore the allocator, the gesture check and the
// note table) cannot tell where a key comes from, and no note index moved --
// key_bus[12] is still the onboard AA13, so "hold AA13 at power-up -> test
// mode" still reads key_held[12].
//
// touch_hi comes from the instantiated mpr121 driver, which contains
// i2c_master; the top level must NOT instantiate i2c_master itself.
//
// Phase 2 of the port: the AX515 N-voice synth (trae\p1_audio_bringup\rtl\
// top_audio.v) re-targeted at the Tang Mega 60K + PT8211 audio chain.
// See docs\阶段2_合成器移植_开工笔记.md sections 3 and 4 for the reasoning.
//
// Signal chain:
//
//  KEY0..14 --> keys_note_ctl --> voice_alloc --> 32 x synth_voice ---+
//               (debounce +      (voice pool)     (DDS + ADSR + gain)  |
//                edge detect)                                         v
//                        pt8211_i2s_tx <-- frame latch <-- scale <-- sequential
//                         (I2S MASTER)                                mix bus
//   UART --> uart_rx --> notify_ctrl --> beep voice (33rd synth_voice)
//                    \-> test mode (0x03 enter / 0x04 exit)
//
// ---------------------------------------------------------------------------
// Differences vs the AX515 original (phase-2 notes, section 3)
// ---------------------------------------------------------------------------
//   1. I2S role   : FPGA is the MASTER now (pt8211_i2s_tx), not a WM8731 slave
//   2. Frame format: LSBJ, 16 BCK per half-frame, WS LOW = RIGHT
//   3. Sample tick : pt8211_i2s_tx.frame_tick   (was lrclk_rise from LRCLK in)
//   4. Mix latch   : frame_tick                 (was lrclk_fall) -- see below
//   5. i2c_config  : DELETED. PT8211 has no registers, so the POR-done signal
//                    replaces config_done; no MCLK / i2c_sclk / i2c_sdat either
//   6. PA_EN       : ADDED and tied LOW (NS4263 SD is an active-low enable;
//                    forgetting it = silence that looks exactly like "I2S is dead")
//   7. NKEYS       : 15 = the 12 MPR121 touch electrodes (ELE0..ELE11, wired in
//                    through key_bus[11:0] by SubTask-004-A) + the 3 onboard
//                    keys AA13 / AB13 / Y12 (key_bus[14:12]); see the pin list
//   8. Fs          : 48828.125 Hz = 50e6 / (64 * DIV), so the FCW table was
//                    recomputed -- see below
//   9. Reset       : POR counter only, no reset key (all 15 keys play notes)
//
// ---------------------------------------------------------------------------
// FCW table:  FCW = f * 2^24 / Fs,  Fs = 50e6/(64*DIV) = 48828.125 Hz
//             coefficient 2^24 / Fs = 343.597384
//   The AX515 constants were computed for 48 kHz (coefficient 349.525333);
//   reusing them verbatim would make every note about 29 cents sharp.
//
// ---------------------------------------------------------------------------
// Octave switch (SubTask-005-A, dimension 2 of Task-005)
//   The two onboard keys that used to be note keys are octave controls now:
//     KEY1 = AB13 = key_bus[13] -> one octave DOWN   (oct_state 2'd0)
//     KEY2 = Y12  = key_bus[14] -> one octave UP     (oct_state 2'd2)
//   Three positions -1 / 0 / +1, reset value = 0, edge triggered off the
//   DEBOUNCED key_on pulses, and CLAMPED at both ends (no wrap-around: pressing
//   "down" while already at -1 leaves the state at -1).
//
//   Where the transposition happens, and why exactly there:
//     the key path's FCW (note_fcw(owner key)) is x2 (up) or /2 (down) and the
//     result is LATCHED per voice into fcw_hold by that voice's attack pulse.
//   Consequences, all of them intended:
//     * it takes effect on the NEXT note-on only. A note already sounding keeps
//       the value latched at its own attack, so changing the octave never bends
//       a held note (no portamento -- this is a switch, not a pitch wheel).
//     * test mode is untouched: test voices take fcw_tst directly and bypass the
//       whole key FCW path, so the 32 test tones stay at 250 + 50k Hz for every
//       octave position. (Checked structurally in sim/tb_top_touch.v T11.)
//     * the notify "beep" voice has its own FCW (fcw_beep) and is not shifted.
//   FCW range: max table entry 269377 (M11) or 269380 (the out-of-range
//   fallback G5); x2 = 538760 < 2^24, so the left shift cannot overflow 24 bits.
//
//   Two side effects that are deliberate and were ruled on (L1):
//     * the pool now has 13 note keys, not 15. key_bus[14:13] are masked out of
//       the allocator (ALLOC_MASK below). The FCW_C5 / FCW_E5 entries stay in
//       note_fcw() but are unreachable from the key bus; key 12 (AA13) still
//       plays A4, so the power-on test-mode gesture is unaffected.
//     * there is NO LED or other indicator for the octave position. The I2C bus
//       permanently took led[2]/led[3] and only led[0] (POR released) and led[1]
//       (a voice is sounding) are left; led[1:0] semantics are FROZEN. The
//       octave position is audible, which is the feedback that carries it.
//
// ---------------------------------------------------------------------------
// Mix scaling (decides whether anything clips, and how loud it is)
//   play path /2^PLAY_SHIFT       : voice_alloc's ownership scheme keeps the
//                  number of sounding pool voices <= NKEYS, so with NKEYS = 15
//                  the sum never exceeds 15 * 32767 = 491505 and
//                  491505 >> PLAY_SHIFT = 7679 still fits in 16-bit signed
//                  (PLAY_SHIFT must be >= 4; the p2_synth value 6 is kept).
//   test mode /2^(LOG2N+TEST_EXTRA): all 32 voices sound at once, sum up to
//                  1048544.
//   Level was tuned by ear on hardware and cross-checked in simulation:
//   the AX515 value (/4) and /16 were both still too loud on this board's
//   3 W amplifier; the current setting is /64 (peak +/-511 per note).
//   sim/tb_top_touch.v measures the real numbers and is the regression test
//   for this: it also proves the idle output is exactly 0.
//   test_tail    : keeps the test scaling after leaving test mode until every
//                  release tail is silent. Without it the 32 tails would be
//                  scaled by the play factor instead of the test one, i.e.
//                  much too loud -> clipping.
//
// ---------------------------------------------------------------------------
// Why the mix is latched on frame_tick (phase-2 notes, section 3.1)
//   pt8211_i2s_tx latches sample_l/sample_r on the frame boundary (the BCK
//   falling edge where WS flips into the RIGHT half-frame) and drives the
//   right MSB from the input port on that very edge -- so both samples must
//   already be stable on that cycle. Therefore frame_tick does all three:
//     (1) advances every voice's DDS/ADSR one step (sample_pulse),
//     (2) restarts the mix accumulator,
//     (3) latches the previous frame's finished sum into mix_frame.
//   The accumulator needs only NVOICE+1 = 33 cycles while a frame lasts
//   50 MHz / Fs = 1024 cycles, so there is ~30x margin. At the frame_tick cycle
//   the I2S block reads the pre-edge mix_frame (non-blocking semantics) = 1
//   frame of delay, plus the latch itself = 2 frames ~= 41 us: inaudible.
//   No extra lrclk_fall-style tick is needed (that was a slave-mode artefact).
//
//   Inherited property, deliberately NOT changed: the accumulator reads
//   voice_samp[0] on the cycle after the tick and voice_samp[g] on cycle
//   tick+1+g, while a voice's new sample appears 2 cycles after the tick.
//   Voice 0 therefore contributes the pre-tick sample and the others the
//   post-tick one -- a one-sample phase offset (about 3 degrees at 440 Hz)
//   between voice 0 and the rest. The AX515 design has exactly the same
//   behaviour (same sample_pulse/mix-trigger relationship), it adds no
//   spectral lines in test mode, and it is inaudible; "fixing" it would mean
//   deviating from the proven original for no audible gain.
//
// ---------------------------------------------------------------------------
// Timing closure (SubTask-006-B, Task-006; L2 ruling Q7 = option (C))
//   Two pipeline changes, both strictly INSIDE this file, both provably
//   frame-level and bit-level transparent. No port / parameter / interface /
//   LED / PA_EN / test-scaling change; no new DSP, no new BSRAM; sine_gen.v
//   and every other read-only file remain byte-identical.
//
//   WHY A DEEPER PIPELINE IS FREE HERE (the budget fact):
//     A frame is 1024 cycles (50 MHz / Fs = 1024) while the mixer scan used only
//     32 of them, so the finished sum already sits in sum_acc ~991 cycles before
//     the frame_tick that latches it into mix_frame. Doubling the scan to 64
//     cycles (2 cycles per voice, change 1 below) therefore still leaves ~960
//     cycles of margin and cannot move a single latched sample: frame-level
//     semantics are unchanged by construction.
//
//   CHANGE 1 -- mixer: one voice per cycle -> two cycles per voice
//     The violated path was  osc LUT -> gain multiply -> 32:1 voice mux ->
//     22-bit adder -> sum_acc  (26.02 ns, 15 logic levels). Registering the mux
//     output in sel_samp splits it in two: the mux now drives only an 18-bit
//     register, and the adder consumes only that register. The state becomes the
//     two-phase pair mix_phase / mix_idx -- phase 0 selects
//     (sel_samp <= voice_samp[mix_idx]), phase 1 adds (sum_acc += sel_samp) and
//     advances mix_idx. 32 voices x 2 phases = 64 cycles, still << 1024.
//
//     BIT-LEVEL READ-POINT PROOF (L2's derivation; why no sample changes value):
//       old read point  : voice g was read on cycle tick+1+g
//       new sample point: voice g is read on cycle tick+1+2g (phase 0 of its pair)
//       * voice 0   : tick+1 in BOTH schemes. The inherited "voice 0 is one
//                     sample behind" quirk documented immediately above is
//                     therefore preserved EXACTLY -- not fixed, not widened.
//       * voice g>=1: the new point tick+1+2g is >= tick+3, while a voice's new
//                     sample is already present and then stable from tick+2 for
//                     the rest of the frame (the "appears 2 cycles after the
//                     tick" fact above). Both the old point (>= tick+2) and the
//                     new one (>= tick+3) consequently latch the SAME post-tick
//                     value.
//       The adder's input is now the register rather than the mux, but the
//       register holds exactly the value read at that cycle -- so the sum is
//       bit-identical to the old one, merely finished 32 cycles later. No
//       multiplier is introduced: sel_samp is a register, not an operator.
//
//   CHANGE 2 -- notify/beep chain: one register before the output mux
//     beep_boost (a combinational saturate/x2 mux) used to feed the output mix
//     mux in the same cycle; it is now registered as beep_boost_r first.
//     Transparent by construction: `mix` is consumed ONLY on frame_tick, and
//     beep_boost is derived from beep_samp, whose upstream registers (sine_gen's
//     osc, adsr's env) are all clocked by the same frame_tick sample_pulse. So
//     beep_boost flips exactly ON the frame_tick edge, never between the two
//     edges that the latch spans -- beep_boost_r holds the pre-edge value that
//     the unregistered mux would have sampled anyway. The latch therefore sees
//     the same number, one cycle of path shorter.
//     sine_gen.v is NOT touched: it belongs to the frozen read-only set whose
//     hash is a B2 criterion.
//
//   FRAME-COMPLETION SELF-CHECK:
//     The 64-cycle scan must finish inside its own frame. An overrun is reported
//     on a NON-counting diagnostic channel ($display -- the mechanism the test
//     bench's zc_sub uses for its own anomalies), never as a chk() assertion, so
//     the TB's assertion count stays exactly 134. The block is wrapped in
//     synopsys translate_off/on: it is simulation-only instrumentation, so it
//     contributes no logic and cannot affect synthesis or PnR.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Latency observer (Task-007)
// ---------------------------------------------------------------------------
//   An embedded, PURELY OBSERVATIONAL key-to-audio latency probe. It lives in
//   this file because it must read two signals that no port carries --
//   key_on[12] (AA13, the onboard key) and key_on[3] (ELE3, a touch electrode)
//   -- plus the completed mix. It DRIVES NOTHING: no existing signal is gated,
//   muxed or reselected by anything below, no port was added, and the mix data
//   path is untouched (the only consumers of `mix` are still mix_frame and, new,
//   a read-only comparator; nothing reads the observer).
//
//   MEASURED QUANTITY -- the anchor, defined word for word the same in
//   sim/tb_top_touch.v:
//     event edge = the frame_tick edge at which the PRE-EDGE |mix| first
//                  crosses the threshold. At a frame_tick edge `mix` is the
//                  completed sum of the frame that just ended (sum_acc's NBA
//                  clear lands after the edge), i.e. exactly the sample the I2S
//                  latch is taking at that same edge -- the same read point.
//     lat_cycles = the number of clk periods from the key_on pulse edge to that
//                  event edge. lat_cnt stops on the event and HOLDS that value,
//                  so lat_cnt after a run IS lat_cycles; no second latch register
//                  exists (that would be 20 more FF and a second truth).
//     "key_on pulse edge" = the edge at which key_on READS HIGH (the debouncer's
//                  edge-detect output is a registered one-cycle pulse, so this is
//                  the first edge that can see it).
//
//   Threshold: LAT_THRESH = 256, SIGNED STRICT comparison
//       detect = frame_tick && (mix > 256 || mix < -256)
//   For one note the transmitted peak is 32767>>6 = 511 (measured in sim by T2),
//   so 256 is "half of one note". No idle or release-tail state can reach it:
//   the idle output is EXACTLY 0 (T1, T4h, T18k), so the first crossing can only
//   come from a real attack ramp.
//
//   FSM (2 states in ONE flip-flop: the state IS lat_busy)
//     IDLE  (lat_busy = 0) : key_on[12] | key_on[3] -> lat_cnt <= 0, ARMED
//     ARMED (lat_busy = 1) : lat_cnt <= lat_cnt + 1 every cycle;
//                            on the event -> lat_busy -> IDLE (lat_cnt holds)
//                            and lat_max takes the new value if it is larger.
//     A start pulse while ARMED RESTARTS the count (lat_cnt <= 0, stays ARMED),
//     so same-cycle competition (start AND event) is documented as START WINS:
//     "the new run begins at this edge".
//   lat_cnt is deliberately NOT clamped on wrap: 20 bits span 1,048,576 cycles
//   (21 ms) while the acceptance band tops out at 500,000 cycles (10 ms), so a
//   wrap can only happen after the criterion has already failed. A clamp would
//   hide that failure instead of reporting it.
//
//   Why 20 bits: ceiling = 10 ms = 500,000 clk, and 2^19 = 524,288 already
//   covers it, but the requirement is stated as "2^20 > 2 x 500,000", i.e. the
//   counter must span MORE THAN two full 10 ms windows: 2^20 = 1,048,576 >
//   1,000,000. In frames: 2^20 clk = 1,024 frames of 1024 clk each.
//
//   RESOURCE ACCOUNTING (the B1 gate: +41 FF, 0 DSP, 0 BSRAM -- L1 hard ceiling)
//     lat_cnt  [19:0]                                            20 FF
//     lat_max  [19:0]                                            20 FF
//     lat_busy (the FSM state, IDLE/ARMED)                        1 FF
//     ----------------------------------------------------------------
//     total                                                       41 FF
//     Everything else in the block is COMBINATIONAL: the +1 incrementer, the
//     20-bit compare-for-max, the start/detect decode and the max multiplexer.
//     `mix` is only READ, so there is no multiplier (0 DSP) and no array
//     (0 BSRAM). lat_test is therefore invisible to the resource report except
//     for those 41 FF.
//   (* syn_keep = "true" *) is on all three registers on purpose: nothing
//   outside this file reads them, so without the attribute a synthesiser may
//   delete the whole observation chain, and the gate would then report the
//   deletion rather than a build. See the B1 gate in the work order.
//
//   Scope: this is a COUNTING observer, NOT an output. How the number reaches a
//   host is the still-open "observation foot" question (option comparison in the
//   SubTask-007-A delivery note); nothing here selects a pin and no .cst file is
//   touched.
//
// Pins (docs\02_Sipeed板卡\pin_constraints\tang_mega_60K_pins.cst;
//       MPR121 placement from Task-008 H6, measured 2026-10-11:
//       the module sits on J9 -- P16 = J9 pin 7 = SCL, R17 = J9 pin 8 = SDA,
//       ADD tied to GND -> 7-bit address 0x5A, IRQ unused (the driver polls the
//       touch-status registers every 5 ms); the board's 10k pull-ups are fitted):
//   clk       = V22 (50 MHz oscillator, SOM)
//   key[2:0]  = AA13 / AB13 / Y12 (BANK9, 1.5 V, internal pull-up, low active)
//               key[0] = AA13 is also the power-on test-mode gesture key
//   i2c_scl   = P16 (J9 pin 7; push-pull, LVCMOS33 + internal pull-up)
//   i2c_sda   = R17 (J9 pin 8; open drain, LVCMOS33 + internal pull-up)
//               P16 / R17 are PERMANENTLY given up to the I2C bus -- they used to
//               be led[3] / led[2]. SCL/SDA must never be moved onto the
//               unusable debug header's pins (MPR121 fact card §1.2 / H6).
//   HP_BCK    = Y17, HP_WS = AB17, HP_DIN = AA16, PA_EN = AB16 (BANK7, 3.3 V)
//   led[1:0]  = R18 T18 (common anode -> LOW = lit)
//               ONLY TWO indicators are left after P16/R17 moved to I2C:
//                 led[0] = POR released   ("configured and running")
//                 led[1] = a pool voice is sounding
//               The former led[1] (any key held) and led[2] (test-mode ~3 Hz
//               blink) are therefore GONE -- the test mode losing its blink
//               indicator is the direct consequence of "the LEDs give way to
//               I2C". The test mode LOGIC (gesture / UART commands / the
//               32-tone spectrum) is deliberately untouched.
//               Why not simply use more LED pins: the official pin file lists
//               eight LED pins, but on GW5AT-60B (this part/package) four of
//               them (U21 / T21 / R19 / P19, sites IOB115[B] / IOB115[A] /
//               IOB113[B] / IOB113[A], CFG column D05 / D04 / D07 / D06) are
//               dedicated CPU pins and PnR rejects them:
//                 ERROR (PR2017) ... the location is a dedicated pin (CPU)
//               The project's CPU option is already false, so they cannot be
//               freed. Two working indicator pins beat eight broken ones.
//   uart_rxd  = V14 (外接 FT2232H 通道B (COM6) TXD; BANK8 = 3.3 V -- see the
//               .cst header note)
//
// Resource note (phase-2 notes, section 4.5): each of the 32 voices carries its
// own 1024x16 wavetable ROM, i.e. 32 * 16 Kb = 512 Kb ~= 40% of the device's
// 1296 Kb BSRAM. This is the tightest resource of the port and the number to
// watch in the synthesis report. The ROMs are intentionally NOT shared and
// time-multiplexed: the scoring metric counts independent oscillators
// (independent phase accumulator + frequency control + envelope), and the 32
// voices below are instantiated in parallel with no time sharing.
// ============================================================================

// ============================================================================
// Timbre selection (SubTask-006-A, Task-006): three timbres, UART 0x05 cycles
// ============================================================================
//   timbre_state (dut.timbre_state, 2 bit, reset 0): 0 = sine, 1 = guzheng,
//                                                    2 = dizi
//   Switching: the UART byte 0x05 steps 0 -> 1 -> 2 -> 0. It takes effect on
//   the NEXT attack only and NEVER bends a sounding note, because every voice
//   latches timbre_state into its own timbre_hold on exactly the same allocator
//   pulse (v_on_alloc[g]) that already latches fcw_hold. The switch is honoured
//   inside test mode as well (the state still moves, but the audio there stays
//   test mode's -- see the constructive-silence argument below); test mode
//   neither sets nor clears timbre_state.
//
// --- timbre 1: "guzheng" = fundamental + 2nd harmonic at 341/1024 -----------
//   For every voice g < COMP_VOICES (=16) a SECOND oscillator + envelope pair
//   (the "companion chain") runs at exactly twice that voice's FCW:
//       comp_osc : sine_gen,      fcw = {fcw_hold[22:0], 1'b0}  (max 1,077,520)
//       comp_env : adsr_envelope, SUSTAIN_LEVEL = 614 (same as the main voice)
//       comp_samp: (comp_osc * comp_env) >> 10     (16 bit signed -- exactly the
//                  gain structure synth_voice uses internally; the harmonic MUST
//                  carry the envelope or it would keep ringing after note-off)
//       harm_pre : (comp_samp * 341) >> 10         (341/1024 = 0.3330078)
//       harm_r   : harm_pre registered on frame_tick
//       voice_out: main + harm_r
//   The ratio is what makes it read as a plucked string instead of a pure sine:
//   the 2nd harmonic sits 9.55 dB below the fundamental.
//   341 = 256+64+16+4+1, so the multiply is written as an EXACT shift-add (L2
//   pre-approved): bit-identical to *341, but LUT logic instead of a DSP block
//   (the naive per-voice form would need up to 96 extra DSPs; the device has 118
//   in total and 33 are already used).
//
//   WHY ONLY g < 16 -- and why that is COMPLETE, not a shortcut:
//     voice_alloc hands out the LOWEST free voice and v_owner_v is never
//     cleared, so a pool that can only ever be fed by the 13 note keys
//     (key_bus[12:0]; key_bus[14:13] are the octave controls and are masked out
//     of the allocator by ALLOC_MASK) reserves exactly voices 0..12. No guzheng
//     voice can therefore ever land on g >= 16, so 16 companion chains cover
//     every voice the guzheng timbre can reach. (A guzheng voice that somehow
//     did land on g >= 16 would fall back to timbre 0's plain sine, harm_r = 0.)
//
//   Overflow budget (why voice_samp is 18 bit, and where the T5 line comes from):
//       |main| <= 32767 ; |harm| <= (32767*341)>>10 = 10911
//       one key  <= 43678       (18-bit signed holds +-131071)
//       13 keys  <= 567814      (22-bit accumulator: 27% used)
//       >> PLAY_SHIFT(6) = 8872 = -11.3 dBFS ; safety line 12000 = -8.7 dBFS
//     The real waveform peak is below "sum of the component peaks":
//     max|sin t + (341/1024)*sin 2t| = 1.1614, i.e. 38055 for one key and
//     494715 for 13 keys, so both assertions are conservative, not tight.
//
// --- timbre 2: "dizi" = sine + +-0.5% vibrato + 200 ms gain ramp ------------
//   Vibrato: ONE shared LFO (sine_gen, FCW_LFO = 1890 -> 5.500624 Hz, +1 ROM)
//   feeds every voice. The vibrato is coherent across voices by design: one LFO
//   costs one ROM and keeps the per-voice logic at a single multiply.
//       lfo_q    = (lfo_samp * 328) >>> 15                     in [-328, +327]
//       fcw_vib  = fcw_hold + ((fcw_hold * lfo_q) >>> 16)      +-0.5% of fcw_hold
//       fcw_vib_r: fcw_vib registered on frame_tick (mandatory: it feeds the DDS
//                  phase adder, the longest combinational path in this block)
//   lfo_q/2^16 = 328/65536 = 0.50049%, so +-0.5% is structural. After the
//   integer truncation the derived depths are +0.49836% / -0.49948% at C4 and
//   +0.49873% / -0.50006% at A4 (all inside the +-0.5% +-0.1% acceptance band).
//
//   Slow attack: a TOP-LEVEL Q30 ramp per voice, NOT an ADSR change -- the
//   Golden adsr_envelope must stay byte-identical:
//       gain_q = ramp_acc[30:20]  (0..1024) ;  dizi_out = (main * gain_q) >> 10
//       step   = +110009 per frame -> full scale after 9761 frames = 199.9 ms
//   ramp_acc priority (L1 ruling 5; the ORDER MATTERS):
//       (1) v_on_alloc[g] & ~v_active[g] -> 0       (fresh attack restarts it;
//                                                    a re-trigger while active
//                                                    does NOT re-fade)
//       (2) test_start                   -> 2^30    (test entry jumps to full
//                                                    gain, so a stale dizi voice
//                                                    cannot sit at half gain)
//       (3) frame_tick & < 2^30          -> +110009 (saturating)
//
// --- the 3:1 timbre mux, and the CONSTRUCTIVE silence argument --------------
//       voice_samp[g] = (timbre_hold == GUZHENG) ? main + harm_r :
//                       (timbre_hold == DIZI)    ? dizi_r       : main
//   There is deliberately NO test_mode term in this mux. Test-mode safety is
//   constructive instead, per branch:
//     * GUZHENG: harm exists only while comp_env is non-zero, and comp_env's
//       note_on/note_off are wired to v_on_alloc/v_off_alloc ONLY -- never to
//       test_start. In test mode alloc_key_on/alloc_key_off are masked to 0, so
//       nothing is allocated, no companion envelope ever leaves IDLE, and harm_r
//       stays exactly 0. (TB T18 asserts comp_env == 0 for every timbre_hold == 1
//       voice while test_mode is 1, after first proving no voice is still held.)
//     * DIZI  : dizi_r = (main * gain_q) >> 10 with gain_q <= 1024 can only
//       attenuate, and test_start forces gain_q to its 1024 maximum, so entering
//       test mode cannot leave a half-open gain behind. Silence still comes from
//       the ADSR inside synth_voice, exactly as for timbre 0.
//     * SINE  : the Golden path, bit-identical to SubTask-005-A.
//   Adding a test_mode term here would double-select against the existing
//   fcw_g = test_mode ? fcw_tst : fcw_eff mux (forbidden by the work order) and
//   would merely MASK the ramp-hole case instead of fixing it.
//
// --- derived constants (re-computed in task/task-006/...precheck...md) ------
//   Fs            = 50e6/(64*16)     = 48828.125 Hz
//   FCW_LFO 1890  -> f_lfo           = 5.500624 Hz (period 8876.8 frames)
//   lfo_q range                      = [-328, +327]
//   vibrato depth                    = 0.4984% .. 0.5001%  (spec +-0.5%)
//   RAMP_STEP 110009 / RAMP_FULL 2^30= 199.91 ms to full gain (spec 200 ms)
//   341/1024                         = 0.3330078 (2nd harmonic -9.55 dB)
//   COMP_VOICES 16                   = +16 ROM ; +1 LFO ROM = +17 BSRAM
//                                      (33 -> 50 of 118 = 42%; budget 60% = 71)
//
// --- segment order discipline (unchanged from SubTask-005-A) -----------------
//   1. TB T1..T11 run FIRST and byte-for-byte unchanged: they are the regression
//      that proves the timbre work broke nothing.
//   2. T12..T18 come AFTER them; every segment asserts the state it depends on
//      and restores timbre_state = SINE (2'd0) before it ends.
//   3. Nothing in this section may change timbre 0's arithmetic: at
//      timbre_state = 0 the mux selects main_ext and the whole addition is a
//      pass-through of the SubTask-005-A netlist.
// ============================================================================

`default_nettype none

module top_touch #(
    parameter integer NVOICE = 32,   // voice pool size (score = voices x Fs)
    parameter integer NKEYS  = 15,   // 15 note keys = the 12 MPR121 touch
                                     // electrodes (key_bus[11:0]) + the 3
                                     // onboard keys (key_bus[14:12]); see the
                                     // header. NB: the key PORT is 3 bits wide
    parameter integer DIV    = 16,   // clk cycles per BCK half period
                                     // DIV=16 -> Fs = 48828.125 Hz

    // Output level, in right shifts. THIS IS THE "VOLUME" KNOB.
    //   mix_play = mix_sum >> PLAY_SHIFT             (play path + notify tone)
    //   mix_test = mix_sum >> (LOG2N + TEST_EXTRA)   (test mode)
    // Both are plain arithmetic shifts of the 22-bit accumulator, then the low
    // 16 bits are kept. That is safe while the shifted value still fits in
    // 16 bits signed:
    //   play : 15 * 32767  = 491505  -> shift >= 4   (NKEYS = 15)
    //   test : 32 * 32767  = 1048544 -> shift >= 6
    //
    // Why so much quieter than the AX515's /4: the AX515 fed a WM8731 headphone
    // output, while this board feeds PT8211 -> LMV321 -> NS4263, a 3 W speaker
    // amplifier with far more gain. Measured on hardware: /4 and /16 were both
    // still too loud. Reference points, verified by simulation (sim/tb_top_touch.v)
    // and by measurement of phase 1's tone_gen, which ran at +/-8191 (-12 dBFS):
    //   PLAY_SHIFT 4 -> single note +/-2047  (-24 dBFS)
    //   PLAY_SHIFT 6 -> single note +/-511   (-36 dBFS)   <- current setting
    //   PLAY_SHIFT 8 -> single note +/-127   (-48 dBFS)
    // Test mode is deliberately scaled so that all 32 voices together land at
    // about 4x one played note, i.e. audible but not startling.
    parameter integer PLAY_SHIFT  = 6,   // /64   (AX515 used /4)
    parameter integer TEST_EXTRA  = 4    // test total /2^(5+4) = /512
)(
    input  wire              clk,       // V22, 50 MHz
    input  wire [2:0]        key,       // the three ONBOARD keys, LOW active,
                                        // internal pull-up: [0] = AA13 (also the
                                        // power-on gesture key), [1] = AB13,
                                        // [2] = Y12. The 12 touch electrodes are
                                        // NOT pins any more -- they arrive via
                                        // the internal key_bus (see the header).

    input  wire              uart_rxd,  // V14, 外接 FT2232H 通道B (COM6) TXD

    output wire              uart_txd,  // U15, 115200 8N1 LAT/LATMAX export

    // W5 (Task-017): the screen's own UART, J8 = PMOD1.  Ball numbers are the
    // authority (dock schematic p19 -> BTB p6/p7):
    //   AB21 = J8 pin 9  = PMOD1_IO2 = BANK8 3.3 V, screen TX -> FPGA
    //   AB22 = J8 pin 10 = PMOD1_IO3 = BANK8 3.3 V, FPGA -> screen RX
    input  wire              uart_rxd2, // AB21, screen TX (0x65 event frames)
    output wire              uart_txd2, // AB22, screen RX (reserved: status
                                        // read-back, W5 optional item 5)

    output wire              HP_BCK,    // Y17  -> PT8211 pin 1
    output wire              HP_WS,     // AB17 -> PT8211 pin 2 (LOW = RIGHT)
    output wire              HP_DIN,    // AA16 -> PT8211 pin 3
    output wire              PA_EN,     // AB16 -> NS4263 SD (LOW = ON)

    output wire [1:0]        led,       // common anode: LOW = lit

    output wire              i2c_scl,   // P16 = J9 pin 7 -> MPR121 SCL (push-pull)
    inout  wire              i2c_sda,   // R17 = J9 pin 8 -> MPR121 SDA (open drain)

    // ==================== D2: DDR3 memory interface (x16, R3 baseline) ======
    output wire [14:0]       ddr_addr,
    output wire [2:0]        ddr_bank,
    output wire              ddr_cs,
    output wire              ddr_ras,
    output wire              ddr_cas,
    output wire              ddr_we,
    output wire              ddr_ck,
    output wire              ddr_ck_n,
    output wire              ddr_cke,
    output wire              ddr_odt,
    output wire              ddr_reset_n,
    output wire [1:0]        ddr_dm,
    inout  wire [15:0]       ddr_dq,
    inout  wire [1:0]        ddr_dqs,
    inout  wire [1:0]        ddr_dqs_n

);

    // ------------------------------------------------------------------ width
    // helpers (constant functions; no $clog2, so old tool chains stay happy)
    function integer clog2v(input integer value);
        integer i;
        begin
            clog2v = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2v = clog2v + 1;
        end
    endfunction

    localparam NKEYW = clog2v(NKEYS);     // NKEYS=15 -> 4 (key index width)
    localparam LOG2N = clog2v(NVOICE);    // NVOICE=32 -> 5 (mix scale shift)

    // ========================================================================
    // Power-on reset
    // ========================================================================
    // Gowin configures every register to 0, so por_cnt starts at 0 and holds
    // reset for 65536 clocks (~1.3 ms at 50 MHz) after configuration.
    // Reset is NOT taken from a key here: all 15 keys are note keys.
    reg [15:0] por_cnt = 16'd0;
    reg        por_n   = 1'b0;

    always @(posedge clk) begin
        if (!por_n) begin
            por_cnt <= por_cnt + 16'd1;
            if (&por_cnt)
                por_n <= 1'b1;
        end
    end

    wire rst_n = por_n;

    // i2c_config's config_done is replaced by POR done: PT8211 has no registers
    // to program, so "ready" simply means "reset released".
    wire tx_en = por_n;

    // ========================================================================
    // MPR121 capacitive-touch chain (SubTask-004-A integration)
    // ========================================================================
    // mpr121 is the SubTask-002 verified driver; it contains i2c_master itself,
    // so i2c_master is deliberately NOT instantiated here. The default
    // parameters are used on purpose (CLK_HZ = 50 MHz, I2C_HZ = 100 kHz), i.e.
    // no parameter override.
    //
    // Polarity (the one thing this integration has to get right):
    //   mpr121.touch is HIGH active (1 = electrode touched), every note key in
    //   this design is LOW active. The 12 electrodes are therefore inverted bit
    //   by bit and concatenated BELOW the three onboard keys:
    //
    //       key_bus[14:0] = {key[2:0], ~touch_hi[11:0]}
    //                        --------  -----------------
    //                        |         +-- touch_lo[11:0]: LOW active
    //                        +-- onboard keys, already LOW active
    //
    //   The whole 15-bit bus is thus uniformly LOW active, and keys_note_ctl
    //   keeps working unchanged. key_bus[12] = key[0] = AA13, so the power-on
    //   test-mode gesture is still key_held[12].
    //
    // init_ok / init_fail are tapped out as internal wires for debug observation
    // ONLY and gate NOTHING -- deliberately, and it is safe by construction:
    // mpr121 holds touch = 0 until its init sequence has succeeded, and
    // 0 -> inverted -> 1 = "released", so no electrode can produce a phantom
    // note before the touch chip answers. (Proven in sim/tb_top_touch.v: with no
    // I2C slave the chain stays in its init_fail -> 1 ms rescan loop and the
    // idle output is still exactly 0.)
    //
    // Timing facts used by the constraints (MPR121 fact card + Task-008 H6):
    //   SCL = P16 = J9 pin 7, SDA = R17 = J9 pin 8, ADD = GND -> address 0x5A,
    //   10k pull-ups already on the module, both pins in BANK8 = 3.3 V.
    wire [11:0] touch_hi;                     // mpr121.touch, HIGH active
    wire [11:0] touch_lo = ~touch_hi;         // same 12 electrodes, LOW active
    wire [14:0] key_bus  = {key, touch_lo};   // [14:12] onboard, [11:0] touch
    wire        touch_init_ok;                // debug observation only
    wire        touch_init_fail;              // debug observation only

    // W5 (Task-017): the SubTask-012-A ELE5 force path (force_val / force_sat /
    // force_valid + the SIM-ONLY attenuation generate block) is DELETED here.
    // 012 was closed by L1 without a production force curve, so this code was
    // dead in the delivery configuration: FORCE_SIM_ENABLE was a constant 0 and
    // synthesis pruned the whole network. Removing it changes no behaviour and
    // removes the last reason for mpr121 to read 0x0E/0x0F/0x23 every 5 ms.

    mpr121 u_touch (
        .clk        (clk),
        .rst_n      (rst_n),
        .touch      (touch_hi),
        .init_ok    (touch_init_ok),
        .init_fail  (touch_init_fail),
        .scl        (i2c_scl),
        .sda        (i2c_sda)
    );

    // ========================================================================
    // I2S master (PT8211) -- also the source of the sample tick
    // ========================================================================
    wire        frame_tick;
    wire [15:0] sample_l;
    wire [15:0] sample_r;

    pt8211_i2s_tx #(
        .DIV (DIV)
    ) u_i2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_l   (sample_l),
        .sample_r   (sample_r),
        .bck        (HP_BCK),
        .ws         (HP_WS),
        .din        (HP_DIN),
        .frame_tick (frame_tick)
    );

    // ========================================================================
    // Keys -> debounce -> per-key note events
    // ========================================================================
    // Asymmetric debounce (1 ms press / 30 ms release): the 30 ms release
    // threshold absorbs contact chatter on worn switches, which would
    // otherwise fire note_off -> note_on pairs and sound "stuttering".
    wire [NKEYS-1:0] key_on, key_off, key_held;
    wire             key_any_held;

    // The key count/width are passed straight through, i.e. the effective
    // instance parameters here are .NKEYS(15) and .NKEYW(4) at the top level's
    // NKEYS = 15 (the form below is deliberately left parameterised).
    // SubTask-004-A: the input is key_bus -- the uniformly LOW-active 15-bit bus
    // {3 onboard keys, 12 inverted MPR121 electrodes}, not the 3-bit key port.
    keys_note_ctl #(
        .NKEYS         (NKEYS),
        .DB_ON_CYCLES  (50_000),      // 1 ms  @50 MHz
        .DB_OFF_CYCLES (1_500_000)    // 30 ms @50 MHz
    ) u_keys (
        .clk      (clk),
        .rst_n    (rst_n),
        .key      (key_bus),          // LOW active: {key[2:0], ~touch_hi[11:0]}
        .key_on   (key_on),           // per-key press pulse   -> allocator
        .key_off  (key_off),          // per-key release pulse -> allocator
        .key_held (key_held),
        .any_held (key_any_held)
    );

    // ========================================================================
    // Screen event bus -- declarations only
    // ========================================================================
    // W5 (Task-017): u_ui_evt (in the UART section below) decodes the TJC 0x65
    // event frames that arrive on the screen's own UART. Its outputs are single
    // clk pulses; they are declared HERE because the octave switches below are
    // the first consumers. Everything else (timbre, test, fx, delay, guide,
    // song) ORs them in at its own decode point further down the file.
    wire       ui_in_frame;      // 0x65 frame in progress (gates legacy bytes)
    wire       ev_valid;         // structurally valid press frame
    wire [7:0] ev_page, ev_obj, ev_event;
    wire       ev_timbre, ev_oct_dn, ev_oct_up;
    wire       ev_fx_toggle, ev_dly_step, ev_guide, ev_song;
    wire       ev_vib;            // L1 W9: obj 10 = vibrato-depth cycle (PC 0x0B)
    wire       ev_rev;            // L1 W10: obj 11 = reverb OFF->R0->R1->R2->OFF
    // Screen-W21: the four new page-1 keys (obj 12..15). Same single-cycle
    // pulse contract as the legacy bus; each is ORed in at its own consumer
    // below, so the existing PC decoders keep their exact priority.
    wire       ev_p32;            // obj 12 = 32-tone TEST on/off (single-key toggle)
    wire       ev_glide;          // obj 12 = sg_glide step   (same as PC 0x0F)
    wire       ev_trem;           // obj 13 = sg_trem step    (same as PC 0x10)
    wire       ev_chorus;         // obj 14 = sg_chorus on/off(same as PC 0x11)
    // Page-0 addendum (2026-10-31): the performance page gets exactly two
    // sendkey=2 keys and they map onto the EXISTING PC echo commands.
    wire       ev_echo;           // obj 16 = sg_echo on/off  (same as PC 0x13)
    wire       ev_echo_dly;       // obj 17 = sg_echo_len delay (same as PC 0x14)
    wire       ev_cho_mix;        // obj 15 = sg_cho_mix       (same as PC 0x12)
    wire       ev_rv_room;        // obj 18 = sg_rv_room       (same as PC 0x0D)
    wire       ev_rv_damp;        // obj 19 = sg_rv_damp       (same as PC 0x0E)

    // ========================================================================
    // Octave switch (SubTask-005-A) -- see the header section of the same name
    // ========================================================================
    // Three positions, edge triggered, clamped. The trigger is the RAW key_on
    // pulse, i.e. taken BEFORE the allocator mask (alloc_key_on below): the key
    // must still be debounced and must still produce exactly one single-cycle
    // event per press, but it must no longer reach the voice pool.
    //
    // While test mode is on, octave changes are still honoured (and still
    // silent): test_mode bypasses the key FCW path entirely, so moving the
    // octave there has no audible effect. The state is deliberately NOT reset by
    // test mode -- leaving test mode returns to the octave you selected.
    //
    // Simultaneous presses: the else-if chain gives key_on[13] (octave DOWN)
    // priority and only one transition can happen per clock. The bench does not
    // cover that case: two mechanical switches cannot be pressed within one
    // 20 ns clock, and the resolution (down wins) is an arbitrary but documented
    // choice rather than a requirement.
    //
    // NB: like the key_held[12] power-on gesture above, this assumes NKEYS >= 15
    // (the two octave controls live at key_bus[14:13]); the only build here is
    // NKEYS = 15.
    localparam [1:0] OCT_DN  = 2'd0,   // -1 octave   (FCW / 2)
                     OCT_MID = 2'd1,   //  0 octave   (reset value, FCW as-is)
                     OCT_UP  = 2'd2;   // +1 octave   (FCW x 2)

    reg [1:0] oct_state;               // TB hierarchical reference: dut.oct_state

    // Screen octave keys (obj 3 / obj 4) drive the SAME state as the onboard
    // KEY1/KEY2. Priority is unchanged: an onboard press still wins a tie.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            oct_state <= OCT_MID;
        else if (key_on[13] || ev_oct_dn)               // KEY1 = AB13 = octave -
            oct_state <= (oct_state == OCT_DN) ? OCT_DN :   // clamp at -1
                         (oct_state == OCT_UP) ? OCT_MID :
                                                 OCT_DN;
        else if (key_on[14] || ev_oct_up)               // KEY2 = Y12 = octave +
            oct_state <= (oct_state == OCT_UP) ? OCT_UP :   // clamp at +1
                         (oct_state == OCT_DN) ? OCT_MID :
                                                 OCT_UP;
    end

    // ========================================================================
    // UART: PC channel + screen channel  (W5 / Task-017)
    // ========================================================================
    // Two independent receivers, one logical command stream:
    //   PC     : uart_rxd  (V14, FT2232H ch.B = COM6), single-byte commands
    //   screen : uart_rxd2 (AB21, J8 pin 9), 0x65 event frames
    // Both are merged at the BYTE level here, and the 0x65 frame parser
    // (u_ui_evt) watches the merged stream. That is what makes the in_frame
    // gate meaningful: while a frame is in progress its bytes (page 0x01,
    // obj 0x05, ...) must not reach the legacy single-byte decoders or the
    // frame "0x65 01 05 01 FF FF FF" would both toggle FX (correct, obj 5) and
    // switch timbre + beep (wrong, bytes 0x05 and 0x01 seen as commands).
    //
    // Collision policy: if both receivers complete a byte on the SAME clock the
    // screen byte wins. The two 0x65 tail bytes are 0xFF, and the legacy
    // commands are all < 0x0A, so a lost PC byte is far less harmful than a
    // lost frame byte; both channels are single-master and this is a
    // documentation choice, not a measured requirement.
    wire [7:0] pc_rx_data;
    wire       pc_rx_done;

    uart_rx #(
        .CLK_HZ (50_000_000),
        .BAUD   (115200)
    ) u_uart (
        .clk     (clk),
        .rst_n   (rst_n),
        .rxd     (uart_rxd),
        .rx_data (pc_rx_data),
        .rx_done (pc_rx_done)
    );

    wire [7:0] scr_rx_data;
    wire       scr_rx_done;

    uart_rx #(
        .CLK_HZ (50_000_000),
        .BAUD   (115200)
    ) u_uart_screen (
        .clk     (clk),
        .rst_n   (rst_n),
        .rxd     (uart_rxd2),
        .rx_data (scr_rx_data),
        .rx_done (scr_rx_done)
    );

    // merged byte stream (screen wins a same-clock collision, see above)
    wire [7:0] rx_data = scr_rx_done ? scr_rx_data : pc_rx_data;
    wire       rx_done = pc_rx_done | scr_rx_done;

    // 0x65 event-frame parser (Task-016 contract: 7 bytes, 1 ms timeout,
    // 200 ms same-key de-bounce). Its in_frame output gates every legacy
    // decode point below: rx_done_eff = rx_done & ~in_frame.
    ui_evt_rx #(
        .CLK_HZ           (50_000_000),
        .FRAME_TIMEOUT_US (1000),
        .DEBOUNCE_US      (200_000),
        .DO_DEBOUNCE      (1)
    ) u_ui_evt (
        .clk         (clk),
        .rst_n       (rst_n),
        .rx_data     (rx_data),
        .rx_done     (rx_done),
        .in_frame    (ui_in_frame),
        .ev_valid    (ev_valid),
        .ev_page     (ev_page),
        .ev_obj      (ev_obj),
        .ev_event    (ev_event),
        .ev_timbre   (ev_timbre),
        .ev_oct_dn   (ev_oct_dn),
        .ev_oct_up   (ev_oct_up),
        .ev_fx_toggle(ev_fx_toggle),
        .ev_dly_step (ev_dly_step),
        .ev_guide    (ev_guide),
        .ev_song     (ev_song),
        .ev_vib      (ev_vib),
        .ev_rev      (ev_rev),
        .ev_p32      (ev_p32),
        .ev_glide    (ev_glide),
        .ev_trem     (ev_trem),
        .ev_chorus   (ev_chorus),
        .ev_echo     (ev_echo),
        .ev_echo_dly (ev_echo_dly),
        .ev_cho_mix  (ev_cho_mix),
        .ev_rv_room  (ev_rv_room),
        .ev_rv_damp  (ev_rv_damp)
    );

    // THE gate. The header byte 0x65 itself is not gated (in_frame can only
    // rise after seeing it) and 0x65 is not a command, so this is safe.
    wire rx_done_eff = rx_done & ~ui_in_frame;

    // Screen transmitter (W5c). Carries exactly the guide-frame bytes that the
    // U15 transmitter streams -- "bt<k>.bco=<colour>" / "t0.txt=\"...\"" plus
    // the FF FF FF terminator, i.e. real TJC instructions -- so the key lights,
    // status line, score and Done become visible on the panel.
    //
    // LAT export text is deliberately NOT mirrored: a TJC parser only executes
    // a buffer that ends in FF FF FF, so non-command bytes left over from a
    // LAT line would prepend garbage to the next instruction and the panel
    // would silently drop it. Only FX_UART_OWN_SCR bytes go to AB22.
    wire [7:0] scr_txd2_data;
    wire       scr_txd2_send;

    // W21 (2026-10-29, screen key follow): byte stream + busy flag from
    // rtl/key_light.v.  The instance itself is near the bottom of this file
    // (it must see guide_state / sta_tx_run), so its nets are declared here
    // for the guide/status arbitration blocks that are textually earlier.
    //   kl_data / kl_send : "bt<k>.bco=2016" / "bt<k>.bco=33808" bytes
    //   kl_busy           : a key-light frame is in flight -> AB22 is owned by
    //                       it; the guide engine must not take FX_UART_OWN_SCR
    //                       and the 40-byte status stream must not issue bytes.
    wire [7:0] kl_data;
    wire       kl_send;
    wire       kl_busy;

    uart_tx #(
        .DIV (434)                              // 50 MHz / 115200
    ) u_uart_txd2 (
        .clk  (clk),
        .rst_n(rst_n),
        .data (scr_txd2_data),
        .send (scr_txd2_send),
        .txd  (uart_txd2),
        .busy ()
    );

    wire notify_trig = rx_done_eff && (rx_data == 8'h01 || rx_data == 8'h02);
    wire notify_on, notify_off, notify_tone, notify_busy;

    notify_ctrl #(
        .CLK_HZ  (50_000_000),
        .BEEP_MS (150),
        .GAP_MS  (200),
        .TAIL_MS (50)
    ) u_notify (
        .clk      (clk),
        .rst_n    (rst_n),
        .trig     (notify_trig),
        .cmd      (rx_data),
        .note_on  (notify_on),
        .note_off (notify_off),
        .tone_sel (notify_tone),
        .busy     (notify_busy)
    );

    // ========================================================================
    // Test mode (the on-site verification requirement)
    // ========================================================================
    // Behaviour: all NVOICE voices attack together, voice k plays
    // f_k = 250 + 50k Hz. With NVOICE=32 that covers 250 Hz..1800 Hz in 50 Hz
    // steps, so a phone spectrum app can count exactly 32 evenly spaced peaks.
    // Enter: (1) power-on gesture -- the onboard KEY0 (key[12] = AA13, was
    //            key[0] while NKEYS was 3) still held when the 100 ms window
    //            closes after reset release (no PC needed on site)
    //        (2) UART 0x03 (enter) / 0x04 (exit)
    // While test mode is on, the keys do not feed the allocator: the only thing
    // being demonstrated is "peak count == voice count".
    wire uart_test_on  = rx_done_eff && (rx_data == 8'h03);
    wire uart_test_off = rx_done_eff && (rx_data == 8'h04);

    reg        test_mode;
    reg [22:0] pon_cnt;         // power-on gesture window: 100 ms = 5_000_000
    reg        pon_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pon_cnt   <= 23'd0;
            pon_done  <= 1'b0;
            test_mode <= 1'b0;
        end else begin
            // The power-on gesture only ever SETS test_mode. Writing
            // `test_mode <= key_held[12]` unconditionally would clear a test
            // mode that the UART had already opened at this exact moment --
            // a real bug in an early AX515 revision, caught by tb_test_mode.v.
            if (!pon_done) begin
                if (pon_cnt == 23'd4_999_999) begin
                    pon_done <= 1'b1;
                    // p6_touch: the gesture key is the ONBOARD KEY0, which is
                    // AA13 = key[12] (it was key[0] while NKEYS was 3). This
                    // keeps "hold the board key at power-up -> test mode".
                    if (key_held[12])
                        test_mode <= 1'b1;
                end else
                    pon_cnt <= pon_cnt + 23'd1;
            end
            // UART commands are honoured at ANY time, including inside the
            // power-on window; if both fire in the same cycle, the UART
            // assignment below wins (last assignment in the block).
            if (uart_test_on)
                test_mode <= 1'b1;
            else if (uart_test_off)
                test_mode <= 1'b0;
            // Screen-W21: page-1 TEST key (obj 12) is a SINGLE-KEY TOGGLE.
            // It is deliberately NOT wired to PC byte 0x13 (0x13 is the D2 DDR
            // echo toggle); the PC 0x03/0x04 semantics above stay untouched.
            else if (ev_p32)
                test_mode <= ~test_mode;
        end
    end

    reg test_mode_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) test_mode_d <= 1'b0;
        else        test_mode_d <= test_mode;
    end
    wire test_start = test_mode  & ~test_mode_d;   // entering: 1-cycle pulse
    wire test_stop  = ~test_mode &  test_mode_d;   // leaving : 1-cycle pulse

    // ========================================================================
    // Timbre selection (SubTask-006-A) -- see the header section of that name
    // ========================================================================
    localparam [1:0] TIMBRE_SINE    = 2'd0,  // 音色 0: plain sine (historical)
                     TIMBRE_GUZHENG = 2'd1,  // 音色 1: sine + 2f at 341/1024
                     TIMBRE_DIZI    = 2'd2;  // 音色 2: sine + vibrato + gain ramp

    reg [1:0] timbre_state;              // TB hierarchical reference: dut.timbre_state
    // W9: the vibrato depth lives in the SAME always block as timbre_state
    // (see below), but is DECLARED here because vlog resolves variables
    // strictly top-down and the block sits above the lfo_q section where the
    // depth-scaling wire lfo_eff is defined.  TB ref: dut.vib_level
    reg [1:0] vib_level;

    // UART 0x05 walks 0 -> 1 -> 2 -> 0. Honoured at ANY time, test mode included
    // (there the state moves while the audio stays test mode's, see the header).
    // test_start / test_stop deliberately do NOT touch this state: leaving test
    // mode returns to the timbre that was selected.
    wire uart_timbre = (rx_done_eff && (rx_data == 8'h05)) || ev_timbre;

    // ---- 0x0B vibrato depth (L1 W9) ---------------------------------------
    // Next-timbre helper: computed once, shared by the timbre_state mux and the
    // auto-preset below (same always block -> no duplicated driver logic).
    wire [1:0] timbre_next = (timbre_state == TIMBRE_SINE)    ? TIMBRE_GUZHENG :
                             (timbre_state == TIMBRE_GUZHENG) ? TIMBRE_DIZI    :
                                                                TIMBRE_SINE;
    // Manual vibrato-depth step: PC byte 0x0B, or screen obj 10 (sb8 sendkey
    // "65 01 0A 01 FF FF FF" -> ui_evt_rx ev_vib).  Single-cycle pulse.
    wire uart_vib = (rx_done_eff && (rx_data == 8'h0B)) || ev_vib;

    // ONE always block drives BOTH timbre_state and vib_level (L1 rule: a
    // second always block on the same signal group would double-drive).  A
    // timbre switch presets the depth (DIZI -> 3, SINE/GUZHENG -> 0) and
    // thereby overrides any manual value; a manual step walks 0 -> 1 -> 2 ->
    // 3 -> 0.  Reset value 0 = no vibrato, so every pre-W9 behaviour (198
    // anchors included) is bit-identical.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timbre_state <= TIMBRE_SINE;
            vib_level    <= 2'd0;                       // power-on: no vibrato
        end else if (uart_timbre) begin
            timbre_state <= timbre_next;
            vib_level    <= (timbre_next == TIMBRE_DIZI) ? 2'd3 : 2'd0;  // auto preset
        end else if (uart_vib) begin
            vib_level <= (vib_level == 2'd3) ? 2'd0 : vib_level + 2'd1;
        end
    end

    // ---- companion-chain depth and dizi-ramp constants --------------------
    // COMP_VOICES bounds the guzheng companion chain. It is COMPLETE rather than
    // arbitrary: the 13 note keys can only ever reserve voices 0..12 (proof in
    // the header), so no guzheng voice can land on g >= COMP_VOICES.
    localparam integer COMP_VOICES = 16;
    // W20 glide covers only the voices that the KEY allocator can ever hand out.
    // Header proof (see the COMP_VOICES note in voice_alloc.v / the top header):
    // the 15-key pool can reserve at most 13 voices and it allocates lowest-first,
    // so play-mode voices are 0..12. Test mode uses all 32 voices but bypasses the
    // whole key FCW path (fcw_g = test_mode ? fcw_tst : fcw_eff), so its 32 tones
    // never glide either. Restricting the slew to 16 voices removed ~3.4k LUT,
    // which was enough to make Gowin routing phase 0 finish (three 25-28 min
    // stalls at 32 voices, 2026-10-29).
`ifdef W20_GLIDE
    // W20 GLIDE ENABLED (2026-10-30 round).  GLIDE_NV = 13 is the EXACT cover
    // of the playable voices, not a round number: the 15-key pool reserves at
    // most 13 voices and voice_alloc allocates lowest-first, so play-mode voices
    // are 0..12 (header proof in voice_alloc.v / the top header).  Test mode uses
    // all 32 voices but bypasses the whole key FCW path
    // (fcw_g = test_mode ? fcw_tst : fcw_eff), so it never glides either.
    // 16 was used in the 2026-10-29 round; 13 trims 19% of the cone because the
    // 16-voice cone made Gowin routing phase 1 stall >24 min on 2026-10-30.
    localparam integer GLIDE_NV    = 13;
`endif
    // NOTE (2026-10-29 lesson -- do NOT repeat it): the first attempt at
    // "glide off" used GLIDE_NV = 0 and relied on the `g < GLIDE_NV` guard
    // being constant-false.  That pruned the DATA path but left +665 Logic /
    // +900 LUT of control residue (seed registers, oct_hold, the TS_MUX event
    // operand mux), and that netlist made Gowin routing diverge for >21 min
    // while the same design without the residue converged in 469 s.
    // The correct switch is `ifdef W20_GLIDE, which removes the block entirely.
    localparam [23:0]  FCW_LFO     = 24'd1890;        // 5.500624 Hz @ Fs
    localparam integer VIB_NUM     = 328;             // 328/65536 = 0.50049%
    localparam [30:0]  RAMP_STEP   = 31'd110009;      // +0.104913 gain/frame (Q30)
    localparam [30:0]  RAMP_FULL   = 31'd1073741824;  // 2^30 -> gain_q = 1024

    // ---- shared LFO (one sine_gen = +1 wavetable ROM, L1 ruling 4) --------
    // Free running: its phase is shared by every dizi voice, so a dizi chord
    // wobbles coherently. T15 measures f_max / f_min over >= 1.5 s (~8 LFO
    // periods), so no per-voice LFO reset is needed.
    wire signed [15:0] lfo_samp;
    sine_gen #(
        .PHASE_W (24),
        .ADDR_W  (10),
        .DATA_W  (16)
    ) u_lfo (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_pulse (frame_tick),
        .fcw          (FCW_LFO),
        .sample_out   (lfo_samp)
    );

    // lfo_q = (lfo_samp * 328) >>> 15.
    // The 32-bit product is exact (|32767*328| = 10,747,576 < 2^24) and the
    // 10-bit slice [24:15] IS the arithmetic shift >>>15 for a value of that
    // magnitude: bit 24 of the product is the sign of the shifted result, so the
    // slice carries the right sign and sign-extends correctly.
    // Range +327 (ROM peak 32767 -> 327.99 -> 327) .. -328 (ROM trough -32767 ->
    // floor(-327.99)); NB the wavetable holds 8001 = -32767, not 8000.
    wire signed [31:0] lfo_prod = $signed(lfo_samp) * 32'sd328;
    wire signed [9:0]  lfo_q    = lfo_prod[24:15];

    // ===== 0x0B vibrato depth (L1 W9; depths boosted, L1 工单 2026-10-25 16:22)
    // ===== zero-DSP: the scaling is SHIFT/ADD only, never a constant multiply
    // vib_level (declared beside timbre_state above, same always block):
    // 0=off (default) 1=+-1.0% 2=+-2.0% 3=+-3.0% of fcw (raw lfo_q = +-0.5%).
    // lfo_s is lfo_q sign-extended 10 -> 13 bits (max |x6| = 6*328 = 1968
    // < 2^12, so 13 signed bits hold every branch without overflow); the
    // scaling is then pure LEFT shifts and one add.  A constant multiply
    // (lfo_q times 6) could infer a DSP block and break the zero-DSP budget --
    // do not "simplify" the shifts away.  Left shifts carry no
    // arithmetic/logical-shift hazard, and every branch is signed, so the
    // result is signed.
    wire signed [12:0] lfo_s  = {{3{lfo_q[9]}}, lfo_q};   // sign-ext 10 -> 13
    wire signed [12:0] lfo_x2 = lfo_s  <<< 1;             // 2x = +-1.0%
    wire signed [12:0] lfo_x4 = lfo_s  <<< 2;             // 4x = +-2.0%
    wire signed [12:0] lfo_x6 = lfo_x4 + lfo_x2;          // 6x = +-3.0%

    wire signed [12:0] lfo_eff =
          (vib_level == 2'd3) ? lfo_x6 :
          (vib_level == 2'd2) ? lfo_x4 :
          (vib_level == 2'd1) ? lfo_x2 : 13'sd0;

    // ========================================================================
    // Note table: FCW = f * 2^24 / 48828.125 = f * 343.597384
    // ========================================================================
    // Touch keys (key[11:0], MPR121 -- Task-004): 12 notes, exact equal
    // temperament with A4 = 440 Hz. FCW = round(f * 343.597384):
    localparam [23:0] FCW_M0   = 24'd89894;   // C4  261.6256 Hz : round(261.6256 x 343.597384) =  89894
    localparam [23:0] FCW_M1   = 24'd100902;  // D4  293.6648 Hz : round(293.6648 x 343.597384) = 100902
    localparam [23:0] FCW_M2   = 24'd113259;  // E4  329.6276 Hz : round(329.6276 x 343.597384) = 113259
    localparam [23:0] FCW_M3   = 24'd119994;  // F4  349.2282 Hz : round(349.2282 x 343.597384) = 119994
    localparam [23:0] FCW_M4   = 24'd134689;  // G4  391.9954 Hz : round(391.9954 x 343.597384) = 134689
    localparam [23:0] FCW_M5   = 24'd151183;  // A4  440.0000 Hz : round(440.0000 x 343.597384) = 151183
    localparam [23:0] FCW_M6   = 24'd169697;  // B4  493.8833 Hz : round(493.8833 x 343.597384) = 169697
    localparam [23:0] FCW_M7   = 24'd179788;  // C5  523.2511 Hz : round(523.2511 x 343.597384) = 179788
    localparam [23:0] FCW_M8   = 24'd201805;  // D5  587.3295 Hz : round(587.3295 x 343.597384) = 201805
    localparam [23:0] FCW_M9   = 24'd226518;  // E5  659.2551 Hz : round(659.2551 x 343.597384) = 226518
    localparam [23:0] FCW_M10  = 24'd239988;  // F5  698.4565 Hz : round(698.4565 x 343.597384) = 239988
    localparam [23:0] FCW_M11  = 24'd269377;  // G5  783.9909 Hz : round(783.9909 x 343.597384) = 269377

    // Onboard keys (key[14:12]): the p2_synth values, kept verbatim on purpose
    // (they are rounded to 0.1 Hz, so C5/G5 differ by a few LSB from M7/M11)
    localparam [23:0] FCW_A4   = 24'd151183;  // 440.0 Hz (A4)  key[12] = AA13 = KEY0
    localparam [23:0] FCW_C5   = 24'd179805;  // 523.3 Hz (C5)  key[13] = AB13 = KEY1
    localparam [23:0] FCW_E5   = 24'd226534;  // 659.3 Hz (E5)  key[14] = Y12  = KEY2
    localparam [23:0] FCW_G5   = 24'd269380;  // 784.0 Hz (G5)  no key: default fallback
    localparam [23:0] FCW_DONE = 24'd302366;  // 880.0 Hz  notify "done"
    localparam [23:0] FCW_ATT  = 24'd452861;  // 1318 Hz   notify "attention"

    // Test mode tones: f_k = 250 + 50k Hz, evenly spaced for peak counting
    localparam [23:0] FCW_T0    = 24'd85899;  // 250 Hz
    localparam [23:0] FCW_TSTEP = 24'd17180;  // 50 Hz step

    // key index -> pitch control word (key-to-pitch mapping lives here only)
    function [23:0] note_fcw(input [NKEYW-1:0] n);
        begin
            case (n)
                4'd0:    note_fcw = FCW_M0;    // key[0]  touch M0 (Task-004)
                4'd1:    note_fcw = FCW_M1;    // key[1]  touch M1
                4'd2:    note_fcw = FCW_M2;    // key[2]  touch M2
                4'd3:    note_fcw = FCW_M3;    // key[3]  touch M3
                4'd4:    note_fcw = FCW_M4;    // key[4]  touch M4
                4'd5:    note_fcw = FCW_M5;    // key[5]  touch M5
                4'd6:    note_fcw = FCW_M6;    // key[6]  touch M6
                4'd7:    note_fcw = FCW_M7;    // key[7]  touch M7
                4'd8:    note_fcw = FCW_M8;    // key[8]  touch M8
                4'd9:    note_fcw = FCW_M9;    // key[9]  touch M9
                4'd10:   note_fcw = FCW_M10;   // key[10] touch M10
                4'd11:   note_fcw = FCW_M11;   // key[11] touch M11
                4'd12:   note_fcw = FCW_A4;    // key[12] AA13       KEY0 -> A4
                4'd13:   note_fcw = FCW_C5;    // key[13] AB13       KEY1 -> C5
                4'd14:   note_fcw = FCW_E5;    // key[14] Y12        KEY2 -> E5
                default: note_fcw = FCW_G5;    // out of range -> fallback pitch
            endcase
        end
    endfunction

    // control word of test-mode voice k (explicit low-24-bit slice keeps the
    // value inside 24 bits, avoiding a width-truncation warning)
    function [23:0] test_fcw(input integer k);
        reg [31:0] v;
        begin
            v        = 32'd85899 + k * 32'd17180;
            test_fcw = v[23:0];
        end
    endfunction

    // ========================================================================
    // Voice pool wiring (declared early: Verilog-2001 needs declaration first)
    // ========================================================================
    wire [NVOICE-1:0]        v_active;        // per-voice busy (ADSR active)
    wire [NVOICE-1:0]        v_on_alloc;      // allocator attack pulses
    wire [NVOICE-1:0]        v_off_alloc;     // allocator release pulses
    wire [NVOICE*NKEYW-1:0]  v_note_flat;     // per-voice pitch index (packed)
                                              // NB: really the owner KEY index,
                                              // see the note in voice_alloc.v

    // ========================================================================
    // Voice allocator: key events -> voice numbers (a pool of NVOICE voices)
    // ========================================================================
    // In test mode the keys stay out of the allocator entirely.
    //
    // SubTask-005-A adds a second mask: key_bus[14:13] are the octave controls
    // now, so they must not allocate voices either. ALLOC_MASK is "every bit set
    // except the top two", i.e. 15'b001_1111_1111_1111 at NKEYS = 15 -- written
    // parameterised so the mask follows NKEYS (requires NKEYS >= 3; the only
    // build here is NKEYS = 15). key_bus[12:0] (AA13 + the 12 touch electrodes)
    // still play notes and the test-mode mask is unchanged.
    localparam [NKEYS-1:0] ALLOC_MASK = {{2{1'b0}}, {(NKEYS-2){1'b1}}};

    wire [NKEYS-1:0] alloc_key_on  = test_mode ? {NKEYS{1'b0}} : (key_on  & ALLOC_MASK);
    wire [NKEYS-1:0] alloc_key_off = test_mode ? {NKEYS{1'b0}} : (key_off & ALLOC_MASK);

    voice_alloc #(
        .NVOICE (NVOICE),
        .NKEYS  (NKEYS),
        .NKEYW  (NKEYW)
    ) u_alloc (
        .clk      (clk),
        .rst_n    (rst_n),
        .key_on   (alloc_key_on),
        .key_off  (alloc_key_off),
        .v_active (v_active),
        .v_on     (v_on_alloc),
        .v_off    (v_off_alloc),
        .v_note   (v_note_flat)
    );

    // Scale hold: after leaving test mode keep the test scaling until every
    // release tail is silent (see the header note -- do not remove this).
    reg test_tail;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            test_tail <= 1'b0;
        else if (test_mode)    test_tail <= 1'b1;
        else if (!(|v_active)) test_tail <= 1'b0;
    end
    wire use_test_scale = test_mode | test_tail;

    // ========================================================================
    // Mix bus: sequential accumulation
    //
    // Why not a parallel adder tree (a real AX515 measurement, worth keeping):
    //   summing NVOICE samples in parallel needs NVOICE-1 adders -- at N=32
    //   that is a 5-level 22-bit adder chain sitting behind the wavetable ROM
    //   read and the gain multiply. Quartus STA measured 23.7 ns from the voice
    //   ROM address register to mix_r, i.e. over the 20 ns period: slack was
    //   +0.77 ns at NVOICE=8, -1.48 at 16, -3.44 at 24, -3.80 at 27.
    //   Sequential accumulation instead needs NVOICE+1 = 33 cycles out of the
    //   1024 cycles per frame (~30x margin) and roughly a third of the logic,
    //   and that logic does not grow with the voice count.
    //
    // This is NOT a time-multiplexed oscillator. All NVOICE phase accumulators,
    // envelope state machines and gain multipliers are separate hardware (see
    // the parallel generate below) and all advance on every sample tick. The
    // only thing "rotated" is which voice's already-computed output is added to
    // the bus on this particular cycle -- a hardware summing bus.
    // ========================================================================
    localparam [LOG2N-1:0] MIX_LAST = NVOICE - 1;

    // SubTask-006-A: 16 -> 18 bit. Timbre 0 still produces at most +-32767 here,
    // but the guzheng branch adds the companion harmonic, whose worst case is
    // 32767 + 10911 = 43678 -- that needs 17 bits and is given 18 for margin.
    // The accumulator below sign-extends from bit 17 accordingly, so timbre 0's
    // sum is bit-identical to SubTask-005-A.
    wire signed [17:0] voice_samp [0:NVOICE-1];  // per-voice enveloped sample

    reg  [LOG2N-1:0]   mix_idx;                  // voice being selected / added
    reg                mix_phase;                // 0 = select cycle, 1 = add cycle
    reg                mix_run;                  // accumulation in progress
    reg  signed [17:0] sel_samp;                 // mux output held (SubTask-006-B)
    reg  signed [21:0] sum_acc;                  // mix accumulator (|sum| < 2^20)

    // SubTask-006-B (Q7 ruling (C)), change 1: the 32:1 voice mux and the 22-bit
    // adder used to sit end to end in ONE cycle -- that was the 26.02 ns critical
    // path. They are now separated by sel_samp at the cost of one extra cycle per
    // voice:
    //   phase 0 : sel_samp <= voice_samp[mix_idx]             (mux -> 18-bit reg)
    //   phase 1 : sum_acc  <= sum_acc + sign_ext(sel_samp)    (reg -> 22-bit add)
    // 32 voices x 2 phases = 64 cycles. Read-point proof in the header comment:
    // voice 0 is still read on tick+1 and every voice g>=1 still contributes its
    // post-tick sample, so the sum is bit-identical -- merely finished 32 cycles
    // later, still ~960 cycles before the frame_tick that consumes it.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_idx   <= {LOG2N{1'b0}};
            mix_phase <= 1'b0;
            mix_run   <= 1'b0;
            sel_samp  <= 18'sd0;
            sum_acc   <= 22'sd0;
        end else if (frame_tick) begin
            // New frame: clear the accumulator and restart the scan at voice 0
            mix_idx   <= {LOG2N{1'b0}};
            mix_phase <= 1'b0;                   // next cycle = phase 0 (select)
            mix_run   <= 1'b1;
            sel_samp  <= 18'sd0;
            sum_acc   <= 22'sd0;
        end else if (mix_run) begin
            if (!mix_phase) begin
                // phase 0 (select): register the voice mux output. This IS the
                // read point -- tick+1 for voice 0, tick+1+2g for voice g.
                sel_samp  <= voice_samp[mix_idx];
                mix_phase <= 1'b1;
            end else begin
                // phase 1 (add): sign-extend the HELD sample to 22 bits and add.
                // SubTask-006-A: the extension is from bit 17 (18-bit voice_samp);
                // the value is unchanged for timbre 0 and cannot overflow for 13
                // keys (13 * 43678 = 567814 < 2^21, i.e. 27% of this accumulator).
                sum_acc   <= sum_acc + {{4{sel_samp[17]}}, sel_samp};
                mix_phase <= 1'b0;
                if (mix_idx == MIX_LAST)
                    mix_run <= 1'b0;             // frame done, sum_acc holds it
                else
                    mix_idx <= mix_idx + 1'b1;
            end
        end
    end

    // ---- frame-completion self-check (SubTask-006-B) -------------------------
    // The 64-cycle scan must finish inside its own 1024-cycle frame. If a
    // frame_tick arrives while mix_run is still set, the scan overran its frame.
    // Reported on a NON-counting diagnostic channel ($display -- the mechanism
    // tb_top_touch.v uses for its own zc_sub anomalies), never as chk(), so the
    // TB assertion count stays exactly 134. translate_off/on keeps it out of
    // synthesis entirely, so it cannot perturb the build or the resource report.
    // synopsys translate_off
    always @(posedge clk) begin
        if (frame_tick && mix_run)
            $display("      MIX_FRAME_OVERRUN ANOMALY: mix_run set at frame_tick (idx=%0d, phase=%b)",
                     mix_idx, mix_phase);
    end
    // synopsys translate_on

    wire signed [21:0] mix_sum = sum_acc;

    // Scale: see PLAY_SHIFT / TEST_EXTRA in the parameter list.
    // Dividing a two's-complement value by 2^n is an arithmetic right shift;
    // keeping the low 16 bits is exact as long as the result fits in 16 bits
    // signed (guaranteed by the bounds documented at the parameter list).
    wire signed [21:0] play_shifted = mix_sum >>> PLAY_SHIFT;
    wire signed [21:0] test_shifted = mix_sum >>> (LOG2N + TEST_EXTRA);
    wire signed [15:0] mix_play = play_shifted[15:0];
    wire signed [15:0] mix_test = test_shifted[15:0];
    wire signed [15:0] note_mix = use_test_scale ? mix_test : mix_play;

`ifdef W20_GLIDE
    // ========================================================================
    // W20 (2026-10-29): GLIDE (portamento) -- polyphonic, exponential
    // ------------------------------------------------------------------------
    // Implemented WITHOUT a per-voice target register and WITHOUT a per-voice
    // ramp register: each voice re-derives its target from the allocator's key
    // index (v_note_flat) plus a 2-bit attack-time octave snapshot, and slews
    // its EXISTING fcw_hold toward it once per frame_tick:
    //
    //     fcw_hold += (target - fcw_hold) >>> k        (k = 11 / 9 / 7)
    //
    //   glide_sel = 0 : OFF (reset value). fcw_hold is latched at attack exactly
    //                   as in F1 -> bit-exact; the slew branch cannot fire.
    //   glide_sel = 1 : slow  (k=11, error to 1% in 193 ms)
    //   glide_sel = 2 : mid   (k=9,  error to 1% in  48 ms)
    //   glide_sel = 3 : fast  (k=7,  error to 1% in  12 ms)
    //
    // Arithmetic width: the largest key FCW is 538760 < 2^20, so the slew runs
    // in 21 signed bits (20 data + 1 guard) and fcw_hold[23:20] stay constant 0.
    // Keeping those four bits constant is what stops the synthesizer from
    // reviving 4 dead FF per voice (32 x 4 = 128 FF). Do NOT widen to 24 bits.
    //
    // Seed: the first note after reset goes straight to its target; every later
    // attack starts from the previous attack's target pitch (one global 24-bit
    // register). "Start from the previous voice's CURRENT pitch" would need a
    // per-voice readback and is deliberately NOT implemented.
    //
    // Vibrato coherency: with glide on, fcw_hold != fcw_oct, so the TS_MUX
    // event operand switches from fcw_oct to this seed (see g_tseng). The
    // vib_ph product still lands one frame late relative to the moving base;
    // worst case at k=7 is 3% x one slew step ~ 0.43 cents -- inaudible.
    //
    // Control: PC single byte 0x0F cycles 0->1->2->3->0. Test mode bypasses the
    // whole key FCW path (fcw_g = test_mode ? fcw_tst : fcw_eff), so glide
    // never touches the 32-peak test tones.
    // Screen-W21: page-1 GLIDE key (obj 13) ORs in here and walks the SAME
    // 0->1->2->3->0 cycle. (PC byte and screen key are mutually exclusive in
    // time; if both landed on one clock the state would still only step once.)
    // ========================================================================
    wire uart_glide = (rx_done_eff && (rx_data == 8'h0F)) || ev_glide;
    reg  [1:0] glide_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            glide_sel <= 2'd0;
        else if (uart_glide)
            glide_sel <= (glide_sel == 2'd3) ? 2'd0 : (glide_sel + 2'd1);
    end

    wire       glide_en = (glide_sel != 2'd0);
    // NOTE (2026-10-30): the old `glide_k` 4-bit shift-amount wire is GONE.
    // The 2026-10-29 optimisation replaced the variable barrel shift with three
    // fixed shifts selected by glide_sel directly, so glide_k had been dead.

    // key index of the voice being attacked on this cycle (lowest index wins if
    // a whole chord lands together); only the seed path consumes it.
    reg [NKEYW-1:0] atk_note;
    integer gi;
    always @* begin
        atk_note = {NKEYW{1'b0}};
        for (gi = NVOICE-1; gi >= 0; gi = gi - 1)
            if (v_on_alloc[gi]) atk_note = v_note_flat[gi*NKEYW +: NKEYW];
    end
    wire [23:0] atk_fcw = note_fcw(atk_note);
    wire [23:0] atk_oct = (oct_state == OCT_UP) ? {atk_fcw[22:0], 1'b0} :
                          (oct_state == OCT_DN) ? {1'b0, atk_fcw[23:1]} :
                                                  atk_fcw;

    reg [23:0] glide_seed;      // previous attack's target pitch
    reg        glide_seed_v;    // at least one attack since reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            glide_seed   <= 24'd0;
            glide_seed_v <= 1'b0;
        end else if (|v_on_alloc) begin
            glide_seed   <= atk_oct;
            glide_seed_v <= 1'b1;
        end
    end

    // ========================================================================
    // W20 2026-10-30 round-2: GLIDE QUALITY GATE (why the first version sounded
    // wrong on the board).  Sliding EVERY attack from the previous pitch makes a
    // normal melody sound permanently out of tune, and sliding across a big jump
    // sounds like a slide whistle.  Two musical gates now decide whether an
    // attack glides at all:
    //
    //   legato   : a key was ALREADY held before this press.  THIS IS SUBTLE:
    //              key_on (the debounced press edge) reaches v_on TWO clocks
    //              later, because voice_alloc queues the press through pend_on.
    //              Delaying key_any_held by one clock is therefore NOT enough --
    //              by the attack cycle the new key has already made key_any_held
    //              high, so the gate would never close (measured: staccato still
    //              glided, any_held_q was 1 on every attack cycle).  Instead the
    //              question is answered AT THE PRESS EDGE: key_held minus key_on
    //              is exactly "the keys that were already down", and that single
    //              bit is latched for the attack that follows.
    //   interval : only slide when the target is within GLIDE_MAX_SEMI semitones of
    //              the seed.  The test is done on the NOTE INDEX (the key number,
    //              which IS the semitone index) rather than on the 24-bit FCW: a
    //              24-bit magnitude compare costs ~2800 LUT here, a 4-bit one costs
    //              about ten.
    //
    // The interval test is done ONCE here on atk_note (the lowest attacking voice's
    // note) rather than per voice.  A per-voice version cost +1650 LUT and made
    // routing stall for >14 min, so it is deliberately global.  For a single note
    // atk_note IS that voice's note, so the decision is exact; for a chord the
    // whole chord follows the lowest note's decision, which is musically right.
    // ========================================================================
    localparam integer GLIDE_MAX_SEMI = 7;
    reg glide_legato_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     glide_legato_q <= 1'b0;
        else if (|key_on) glide_legato_q <= |(key_held & ~key_on);
    end
    reg [NKEYW-1:0] glide_seed_note;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            glide_seed_note <= {NKEYW{1'b0}};
        else if (|v_on_alloc)  glide_seed_note <= atk_note;
    end
    wire             glide_legato = glide_legato_q;
    wire [NKEYW-1:0] atk_ivl = (atk_note >= glide_seed_note)
                             ? (atk_note - glide_seed_note)
                             : (glide_seed_note - atk_note);
    wire             atk_far  = (atk_ivl > GLIDE_MAX_SEMI);
    wire             glide_ok = glide_en && glide_seed_v && glide_legato && !atk_far;
`endif

    // ========================================================================
    // NVOICE parallel voices (each with its own phase accumulator and envelope;
    // nothing here is time-shared)
    // ========================================================================
`ifdef TS_MUX
    // ========================================================================
    // P1 DSP time-multiplexing (W8 L2 approval, plan A).  The 96 per-voice
    // multipliers (3 operators x NVOICE) become ONE shared multiplier per
    // operator, swept once per 1024-cycle frame into per-voice HOLD registers.
    // The original frame_tick capture registers (fcw_vib_r, harm_r, dizi_r)
    // are kept VERBATIM below and now capture from the holds, so at every
    // frame_tick edge they latch bit-identical values -> bit-exact audio.
    // Round-2 layout: DSP 96 -> 12 (4 groups x 3 shared multipliers).
    //
    // Event correctness (voice_alloc v_on pulses are NOT frame-synchronised):
    //   * fcw_hold[g] reload (v_on_alloc[g]): that voice's vib hold is
    //     recomputed IN THE EVENT CYCLE on the shared vib multiplier (event
    //     priority; a concurrent vib sweep slot stalls one cycle) using the
    //     NEW operand fcw_oct[g] -- exactly what the original combinational
    //     product would present at the next frame_tick edge.
    //   * ramp reset (v_on_alloc[g] && !v_active[g]): gain_q -> 0, so the
    //     dizi hold is forced to 0 (no multiplier).
    //   * test_start: gain_q -> 1024 = RAMP_FULL[30:20] (a constant), so all
    //     dizi holds reload with main_samp * 1024 in parallel; a constant
    //     multiply folds to a shift, no DSP.
    // Budget: 80 base slots (32 vib + 16 comp + 32 dizi) + event stalls,
    // worst case < 120 of 1024 cycles (W8 hard condition: <= 80%).
    // ts_busy_acc counts the busy cycles of each frame for the equivalence TB.
    // ========================================================================
    wire [NVOICE*24-1:0] fcw_hold_flat;     // per-voice operand snapshots
    wire [NVOICE*24-1:0] fcw_oct_flat;      // (written by the g_voice loop)
    wire [NVOICE*16-1:0] main_samp_flat;
    wire [NVOICE*11-1:0] gain_q_flat;
    wire [NVOICE*16-1:0] comp_osc_flat;     // voices >= COMP_VOICES pad 0
    wire [NVOICE*11-1:0] comp_env_flat;

    reg  signed [31:0] vib_ph  [0:NVOICE-1];
    reg  signed [27:0] comp_ph [0:COMP_VOICES-1];
    reg  signed [27:0] dizi_ph [0:NVOICE-1];

    // W8 round-2b (L2 directive): GROUPED time-multiplexing, 8 groups x 4
    // voices (grp = voice[5:3], li = voice[1:0]); each group owns 3 shared
    // multipliers (vib/comp/dizi) = 24 total, synthesized next to its
    // 4-voice array with 4:1 operand muxes.  Escalation of the 4x8 layout
    // (12 multipliers) whose PnR routing was still grinding: even shorter
    // group-local nets, at the cost of 24 engine multipliers (gate <= 94).
    // Hold arrays, operand definitions, widths and the event / wait-state
    // semantics are UNCHANGED -> bit-exactness preserved.
    // Per-group sweep: 3 wait states (29..31) + 12 slots (vib 0..3,
    // comp 4..7 -- groups 4..7 have no companion chain, their comp slots
    // idle; dizi 8..11).  Busy <= 3+12+event stalls of 1024 (limit 819).
    wire [7:0] ts_run_bus;

    // C: finish the FCW capture one clk after frame_tick. No frame protocol change.
    reg vib_finalize;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vib_finalize <= 1'b0;
        else        vib_finalize <= frame_tick;
    end

    genvar gg;
    generate
    for (gg = 0; gg < 8; gg = gg + 1) begin : g_tseng
        // group-local event view (v_on_alloc is globally one-hot)
        wire [3:0] ev_oh = v_on_alloc[gg*4 +: 4];
        wire       ev_g  = |ev_oh;
        reg  [1:0] ev_li;
        integer    ei;
        always @* begin
            ev_li = 2'd0;
            for (ei = 3; ei >= 0; ei = ei - 1)
                if (ev_oh[ei]) ev_li = ei[1:0];
        end

        reg [4:0] ts_idx_g;                   // 29..31 wait | 0..11 slots
        reg       ts_run_g;
        assign ts_run_bus[gg] = ts_run_g;

        wire [1:0] li     = ts_idx_g[1:0];
        wire       s_vib  = ts_run_g & (ts_idx_g <  5'd4);
        wire       s_comp = ts_run_g & (ts_idx_g >= 5'd4)  & (ts_idx_g < 5'd8);
        wire       s_dizi = ts_run_g & (ts_idx_g >= 5'd8)  & (ts_idx_g < 5'd12);

        // group-local 4:1 operand muxes; the event's NEW fcw_oct wins on vib
        wire [23:0] fcw_hold_g = fcw_hold_flat[(gg*4+li)*24 +: 24];
        // W20 glide: the event operand must be the pitch fcw_hold is ABOUT to
        // take -- the seed while gliding, the target when glide is off. Mixing
        // the target operand with a seed base would put the vib product on a
        // different pitch generation (advisory review section 3.4).
`ifdef W20_GLIDE
        // The event operand must follow the SAME decision as the attack mux
        // (glide_ok), otherwise a non-gliding note would compute its vibrato
        // product on the seed instead of on its own target pitch.
        wire [23:0] vib_ev_a  = glide_ok ? glide_seed
                                        : fcw_oct_flat[(gg*4+ev_li)*24 +: 24];
`else
        // No glide: the event operand is the target pitch, exactly as in F1.
        wire [23:0] vib_ev_a   = fcw_oct_flat[(gg*4+ev_li)*24 +: 24];
`endif
        wire [23:0] vib_a_g    = ev_g ? vib_ev_a : fcw_hold_g;
        wire [15:0] comp_osc_g = comp_osc_flat[(gg*4+li)*16 +: 16];
        wire [10:0] comp_env_g = comp_env_flat[(gg*4+li)*11 +: 11];
        wire [15:0] main_g     = main_samp_flat[(gg*4+li)*16 +: 16];
        wire [10:0] gain_q_g   = gain_q_flat  [(gg*4+li)*11 +: 11];
        wire        act_ev_g   = v_active[gg*4+ev_li];

        // Widths/casts replicate the original per-voice expressions bit for bit
        // (W9: lfo_eff replaces lfo_q -- depth-scaled; W10 工单: depths are
        // 1/2/3% via shift/add in lfo_eff itself, this line is UNCHANGED)
        // B/C stage 0: one request per group per clk, with a full-rate pipe.
        reg        vib_valid_q;
        reg [1:0]  vib_dst_q;
        reg [23:0] vib_a_q;
        reg signed [12:0] vib_lfo_q;
        wire signed [31:0] mul_vib_g =
            $signed({1'b0, vib_a_q}) * $signed(vib_lfo_q);
        wire signed [27:0] mul_comp_g = $signed(comp_osc_g)
                                      * $signed({1'b0, comp_env_g});
        wire signed [27:0] mul_dizi_g = $signed(main_g)
                                      * $signed({1'b0, gain_q_g});

        integer ci;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                ts_idx_g <= 5'd0;  ts_run_g <= 1'b0;
                vib_valid_q <= 1'b0;
                vib_dst_q   <= 2'd0;
                vib_a_q     <= 24'd0;
                vib_lfo_q   <= 13'sd0;
                for (ci = 0; ci < 4; ci = ci + 1) begin
                    vib_ph [gg*4+ci] <= 32'sd0;
                    dizi_ph[gg*4+ci] <= 28'sd0;
                    if (gg*4+ci < COMP_VOICES) comp_ph[gg*4+ci] <= 28'sd0;
                end
            end else begin
                if (frame_tick) begin
                    // 3 wait states (29..31): sine_gen's sample_r follows the
                    // phase acc with a 1-clk lag and main_samp with 2, so
                    // slots must not read operands in the frame's first
                    // cycles; events inside the window are corrected by the
                    // full sweep afterwards.
                    ts_idx_g <= 5'd29;  ts_run_g <= 1'b1;
                end else if (ts_run_g) begin
                    if (!(ev_g && s_vib)) begin       // event stole the vib bus
                        if (ts_idx_g == 5'd11) ts_run_g <= 1'b0;
                        else                   ts_idx_g <= ts_idx_g + 5'd1;
                    end
                end
                // Do NOT flush the pipe on frame_tick. Event wins at input.
                vib_valid_q <= ev_g || s_vib;
                if (ev_g || s_vib) begin
                    vib_dst_q <= ev_g ? ev_li : li;
                    vib_a_q   <= vib_a_g;
                    vib_lfo_q <= lfo_eff;
                end
                // Stage 1: consume the preceding clock's tagged operands.
                if (vib_valid_q)
                    vib_ph[gg*4+vib_dst_q] <= mul_vib_g;
                if (s_comp && (gg < 4))               // comp chain: voices 0..15
                    comp_ph[gg*4+li] <= mul_comp_g;
                if (test_start) begin
                    for (ci = 0; ci < 4; ci = ci + 1)
                        dizi_ph[gg*4+ci] <= $signed(main_samp_flat[(gg*4+ci)*16 +: 16])
                                            * $signed(12'd1024);
                end else if (ev_g && !act_ev_g) begin
                    dizi_ph[gg*4+ev_li] <= 28'sd0;    // ramp reset -> gain_q = 0
                end else if (s_dizi) begin
                    dizi_ph[gg*4+li] <= mul_dizi_g;
                end
            end
        end
    end
    endgenerate

    // global busy counter for the equivalence bench: cycles in which any
    // group is sweeping (frame-anchored, read by tb_tsmux_equiv).
    reg  [9:0] ts_busy_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           ts_busy_acc <= 10'd0;
        else if (frame_tick)  ts_busy_acc <= 10'd0;
        else if (|ts_run_bus) ts_busy_acc <= ts_busy_acc + 10'd1;
    end
`endif
    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_voice
            wire [NKEYW-1:0] note_g  = v_note_flat[g*NKEYW +: NKEYW];
            wire [23:0]      fcw_key = note_fcw(note_g);   // pitch from allocator
            wire [23:0]      fcw_tst = test_fcw(g);        // fixed test-mode pitch

            // ---- octave transposition (SubTask-005-A), key path only --------
            // Combinational and applied BEFORE the attack latch below:
            //   OCT_UP  : FCW x 2    (one octave up)
            //   OCT_DN  : FCW / 2    (one octave down -- FCW is an unsigned
            //                         positive value, so the logical (zero
            //                         filling) right shift is the correct halving)
            //   OCT_MID : unchanged
            // Both shifts are pure wiring, so this costs no logic beyond 32 muxes.
            wire [23:0]      fcw_oct = (oct_state == OCT_UP) ? {fcw_key[22:0], 1'b0} :
                                       (oct_state == OCT_DN) ? {1'b0,  fcw_key[23:1]} :
                                                               fcw_key;   // OCT_MID

            // ---- attack-time latch ------------------------------------------
            // Sampled by the ALLOCATOR's own single-cycle pulse v_on_alloc[g]
            // ONLY. Do not "simplify" this to v_on_g: that signal also carries
            // test_start, so a test-mode entry would latch a key-path pitch into
            // all 32 test voices (they would then play the wrong tone after
            // leaving test mode).
            // v_on_alloc is a register output of voice_alloc (assigned in its
            // posedge-clk block, single driver), so it is stable for the whole
            // cycle and this enable needs neither filtering nor synchronising.
            // !rst_n clears the latch; the voices are IDLE then, so the value is
            // only ever observed after a real attack has written it.
`ifdef W20_GLIDE
            // ---- W20 glide (portamento): 2-bit attack-time octave snapshot ----
            // oct_hold freezes the octave AT ATTACK TIME (the F1 semantic: a held
            // note must not bend when the octave switch moves), so the glide
            // target is rebuilt from the key index + oct_hold instead of the live
            // oct_state that fcw_oct reads.
            reg [1:0] oct_hold;
            wire [23:0] fcw_key_h = (oct_hold == OCT_UP) ? {fcw_key[22:0], 1'b0} :
                                    (oct_hold == OCT_DN) ? {1'b0, fcw_key[23:1]} :
                                                            fcw_key;
`endif
            // fcw_hold: F1 = attack-latched pitch; with W20_GLIDE it is the
            // slew accumulator (same register, no extra flops).
            reg [23:0] fcw_hold;                 // current pitch
`ifdef W20_GLIDE
            // 21-bit signed slew on the EXISTING fcw_hold (see the W20 GLIDE block
            // comment above for why 21 and not 24 bits).
            // 2026-10-29 BATCH-1 LESSON: the first version used a VARIABLE barrel
            // shift (g_diff >>> glide_k). That cost ~130 LUT per voice and pushed
            // this datapath to 25 logic levels -> Fmax 48.834 MHz with setup TNS
            // -16.829 ns over 69 endpoints (all ending at fcw_hold). Fixed shifts
            // are pure wiring, so three speeds now cost only two 21-bit muxes.
            wire        [19:0] g_tgt   = fcw_key_h[19:0];
            wire        [19:0] g_cur   = fcw_hold[19:0];
            wire signed [20:0] g_diff  = $signed({1'b0, g_tgt}) - $signed({1'b0, g_cur});
            wire signed [20:0] g_shr7  = g_diff >>> 7;
            wire signed [20:0] g_shr9  = g_diff >>> 9;
            wire signed [20:0] g_shr11 = g_diff >>> 11;
            wire signed [20:0] g_shr   = (glide_sel == 2'd3) ? g_shr7 :
                                         (glide_sel == 2'd2) ? g_shr9 : g_shr11;
            // convergence: at least +-1 LSB per frame so the slew always lands ON
            // the target; the shifted step is zero only within the last few LSB,
            // where the sign of the error picks the direction.
            wire g_zero  = ~(|g_diff[20:0]);
            wire g_shr_z = ~(|g_shr[20:0]);
            wire signed [20:0] g_step  = g_zero     ? 21'sd0   :
                                         (!g_shr_z) ? g_shr   :
                                         g_diff[20] ? -21'sd1 : 21'sd1;
            wire        [20:0] g_sum   = $signed({1'b0, g_cur}) + g_step;
            wire        [23:0] fcw_glided = g_sum[20] ? 24'd0 : {4'd0, g_sum[19:0]};

`endif
            // SubTask-006-A: the timbre is latched by the SAME pulse, in the SAME
            // always block. That is what makes "the switch takes effect on the
            // next attack only and never bends a sounding note" structural rather
            // than something to be tested for. TB: dut.g_voice[g].timbre_hold
            reg [1:0]  timbre_hold;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    fcw_hold    <= 24'd0;
`ifdef W20_GLIDE
                    oct_hold    <= OCT_MID;
`endif
                    timbre_hold <= TIMBRE_SINE;
                end else if (v_on_alloc[g]) begin
`ifdef W20_GLIDE
                    oct_hold    <= oct_state;
`endif
                    timbre_hold <= timbre_state;
`ifdef W20_GLIDE
                    // glide_ok is the global quality gate (legato + interval);
                    // the (g < GLIDE_NV) term keeps the cone inside 13 voices.
                    if (!glide_ok || (g >= GLIDE_NV))
                        fcw_hold <= fcw_oct;              // direct to target
                    else
                        fcw_hold <= glide_seed;           // glide from previous pitch
`else
                    fcw_hold <= fcw_oct;                  // F1 behaviour, bit-exact
`endif
                end
`ifdef W20_GLIDE
                else if (glide_en && frame_tick && (g < GLIDE_NV)) begin
                    fcw_hold <= fcw_glided;               // one slew step per frame
                end
`endif
            end

            // ---- dizi vibrato (SubTask-006-A) --------------------------------
            // fcw_vib = fcw_hold + ((fcw_hold * lfo_q) >>> 16). lfo_q/2^16 is
            // 328/65536 = 0.50049%, so the peak deviation is +-0.5% of fcw_hold;
            // after the integer truncation the derived depths are +0.49836% /
            // -0.49948% at C4 and +0.49873% / -0.50006% at A4.
            // The 32-bit product is exact (max |538760*328| = 1.77e8 < 2^28), and
            // [31:16] with an explicit sign extension IS that product >>> 16.
`ifdef TS_MUX
            // P1 TS_MUX: product from the event-maintained hold -- bit-identical
            // to the combinational multiply at every frame_tick edge.
            wire signed [31:0] vib_prod  = vib_ph[g];
`else
            // W10 (深度提升工单): lfo_eff (13 b) replaces lfo_q here too, so
            // the non-TS_MUX build honours the depth select as well -- the W9
            // intent ("lfo_eff replaces lfo_q", see the TS_MUX operand note)
            // missed this line.  Product bound 538760 x 1968 = 1.06e9 < 2^31:
            // the 32-bit context is exact, no width change needed.
            wire signed [31:0] vib_prod  = $signed({1'b0, fcw_hold}) * lfo_eff;
`endif
            wire signed [23:0] vib_delta = {{8{vib_prod[31]}}, vib_prod[31:16]};
            // fcw_hold <= 538760 < 2^23, so bit 23 is always 0: this is a 24-bit
            // signed copy of fcw_hold (same value, no width warning either).
            wire signed [23:0] fcw_vib   = $signed({1'b0, fcw_hold[22:0]}) + vib_delta;

            // MANDATORY pipeline register (L1 ruling 5): fcw_vib feeds the DDS
            // phase adder, the longest combinational path in this block.
            reg [23:0] fcw_vib_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) fcw_vib_r <= 24'd0;
`ifdef TS_MUX
                // On F, DDS reads the OLD completed FCW. Reuse this same register
                // to hold the pre-edge-F base, including attack/glide NBA semantics.
                else if (frame_tick)
                    fcw_vib_r <= {1'b0, fcw_hold[22:0]};
                // At F+1, delayed vib_ph has exactly the old pre-F history.
                // A concurrent vib_ph write at F+1 is intentionally read OLD.
                else if (vib_finalize)
                    fcw_vib_r <= $signed(fcw_vib_r) + vib_delta;
`else
                else if (frame_tick) fcw_vib_r <= fcw_vib;
`endif
            end

            // W9 (0x0B vibrato depth): vibrato is now GLOBAL -- every timbre.
            // level == 0 selects fcw_hold DIRECTLY (the same wire the 198
            // anchors measured; no fcw_vib_r register stage in the path, so
            // zero added frame_tick latency).  level != 0 selects fcw_vib_r.
            // The select is the LIVE global vib_level (not the per-voice
            // latched timbre_hold), so a manual depth change is heard
            // immediately on every sounding voice -- the designed behaviour of
            // the 0->1->2->3 screen button.  (The dizi slow-attack gain ramp is
            // a DIFFERENT mux further below and still keys off timbre_hold.)
            wire [23:0]      fcw_eff = (vib_level == 2'd0) ? fcw_hold : fcw_vib_r;
            // T11 of SubTask-005-A references this exact name: test mode must
            // still short-circuit the WHOLE key + timbre FCW path.
            wire [23:0]      fcw_g   = test_mode ? fcw_tst : fcw_eff;
            wire             v_on_g  = test_start | v_on_alloc[g];
            wire             v_off_g = test_stop  | v_off_alloc[g];

            // ---- dizi slow-attack ramp (SubTask-006-A) -----------------------
            // A TOP-LEVEL gain ramp; the Golden adsr_envelope is not touched.
            // Priority is fixed by L1 ruling 5, and the ORDER MATTERS:
            //   (1) a fresh attack (allocator pulse while this voice is idle)
            //       restarts the ramp at 0. A RE-trigger while the voice is still
            //       active does NOT restart it, so re-pressing a held key does
            //       not fade the note in again.
            //   (2) entering test mode jumps straight to full gain, so a stale
            //       dizi voice can never sit at a half-open gain inside test mode
            //   (3) otherwise ramp up once per frame, saturating at 2^30
            // Full scale after 9761 frames = 199.9 ms ("200 ms slow attack").
            reg [30:0] ramp_acc;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    ramp_acc <= 31'd0;
                else if (v_on_alloc[g] && !v_active[g])
                    ramp_acc <= 31'd0;
                else if (test_start)
                    ramp_acc <= RAMP_FULL;
                else if (frame_tick && (ramp_acc < RAMP_FULL))
                    ramp_acc <= ramp_acc + RAMP_STEP;
            end
            wire [10:0] gain_q = ramp_acc[30:20];    // TB: dut.g_voice[g].gain_q

            wire signed [15:0] main_samp;            // raw synth_voice output

            synth_voice #(
                .SUSTAIN_LEVEL (21'd614)          // 0.6 x 1024 (velocity entry)
            ) u_voice (
                .clk          (clk),
                .rst_n        (rst_n),
                .sample_pulse (frame_tick),       // DDS/ADSR step once per frame
                .note_on      (v_on_g),
                .note_off     (v_off_g),
                .fcw          (fcw_g),
                .sample_out   (main_samp),
                .env          (),                 // reserved for visualisation
                .active       (v_active[g])
            );

`ifdef TS_MUX
            // operand snapshot for the shared-multiplier sweep (plan A)
            assign fcw_hold_flat [g*24 +: 24] = fcw_hold;
            assign fcw_oct_flat  [g*24 +: 24] = fcw_oct;
            assign main_samp_flat[g*16 +: 16] = main_samp;
            assign gain_q_flat   [g*11 +: 11] = gain_q;
`endif

            // ---- guzheng companion chain (g < COMP_VOICES only) --------------
            // The ROM + envelope pair is instantiated ONLY for the voices the 13
            // note keys can ever reserve (proof in the header), which is what
            // keeps the BSRAM cost at +16 instead of +32.
            wire        [10:0] comp_env;     // TB: dut.g_voice[g].comp_env
            wire signed [15:0] comp_samp;    // companion oscillator x its envelope
            // NB: no generate/endgenerate pair here -- a conditional generate
            // inside a loop generate body is written as a BARE if (Verilog-2001
            // forbids nesting generate regions; ModelSim: vlog-13060).
            if (g < COMP_VOICES) begin : g_comp
                // Twice the voice FCW: {x[22:0],1'b0} = x*2.  Source is
                // fcw_eff (L1 催办 2026-10-25 §一): the 2nd harmonic must
                // follow the SAME vibrato-deviated fcw the fundamental uses,
                // else with vibrato on the two layers decouple and beat
                // against each other ("harmonic energy undulates, pitch does
                // not move" -- reproduced on hardware).  fcw_eff === fcw_hold
                // at level 0, so the level-0 path is bit-identical to the
                // pre-W10 behaviour.  Range: |fcw_eff| <= 538760 + 2694
                // (level-3 deviation at max fcw) < 2^23, so the [22:0] slice
                // is lossless and the left shift cannot wrap (<= 1082908 <
                // 2^24).
                wire [23:0] comp_fcw = {fcw_eff[22:0], 1'b0};
                wire [15:0] comp_osc;

                sine_gen #(
                    .PHASE_W (24),
                    .ADDR_W  (10),
                    .DATA_W  (16)
                ) u_comp_osc (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .sample_pulse (frame_tick),
                    .fcw          (comp_fcw),
                    .sample_out   (comp_osc)
                );

                // The events are the ALLOCATOR pulses ONLY. Wiring test_start in
                // here would make the 2nd harmonic sound during test mode; this
                // is the constructive half of "test mode is timbre 0".
                adsr_envelope #(
                    .SUSTAIN_LEVEL (21'd614)
                ) u_comp_env (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .sample_pulse (frame_tick),
                    .note_on      (v_on_alloc[g]),
                    .note_off     (v_off_alloc[g]),
                    .env          (comp_env),
                    .active       ()
                );

`ifdef TS_MUX
                // P1 TS_MUX: comp_samp comes from the shared-multiplier hold.
                // Its only consumer (harm_r) captures at frame_tick, when the
                // hold already carries this frame's product.
                wire signed [27:0] comp_prod = comp_ph[g];
                assign comp_samp = comp_prod[25:10];
                assign comp_osc_flat[g*16 +: 16] = comp_osc;
                assign comp_env_flat[g*11 +: 11] = comp_env;
`else
                // Same gain structure as synth_voice: osc(16) x env(11) >> 10.
                wire signed [27:0] comp_prod = $signed(comp_osc) * $signed({1'b0, comp_env});
                assign comp_samp = comp_prod[25:10];
`endif
            end else begin : g_nocomp
                assign comp_env  = 11'd0;
                assign comp_samp = 16'sd0;
`ifdef TS_MUX
                // pad (never selected: comp slots only sweep sv = 0..15)
                assign comp_osc_flat[g*16 +: 16] = 16'd0;
                assign comp_env_flat[g*11 +: 11] = 11'd0;
`endif
            end

            // 341 = 256+64+16+4+1, written as an EXACT shift-add (L2 pre-approved):
            // bit-identical to (comp_samp * 341) -- every partial product and
            // partial sum fits the 26-bit signed intermediate -- but it costs LUT
            // logic instead of one DSP block per voice.
            // NB the result is taken with an ARITHMETIC SHIFT, not with a
            // part-select: a part-select is UNSIGNED in Verilog, so writing
            // harm_mul[24:10] would zero-extend and corrupt every negative
            // half-cycle (harm came out ~3x too large in the pre-run
            // micro-benchmark, task/task-006 SubTask-006-A micro evidence).
            wire signed [25:0] csx = {{10{comp_samp[15]}}, comp_samp};   // sign-extend
            wire signed [25:0] harm_mul = (csx << 8) + (csx << 6) + (csx << 4)
                                        + (csx << 2) + csx;
            wire signed [15:0] harm_pre = harm_mul >>> 10;   // == (comp_samp*341) >>> 10

            reg signed [15:0] harm_r;                        // frame_tick pipeline
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)          harm_r <= 16'sd0;
                else if (frame_tick) harm_r <= harm_pre;
            end

            // ---- dizi output gain -------------------------------------------
`ifdef TS_MUX
            // P1 TS_MUX: product from the hold (event-maintained, see the
            // engine above); dizi_r still captures at frame_tick.
            wire signed [27:0] dizi_prod = dizi_ph[g];
`else
            wire signed [27:0] dizi_prod = $signed(main_samp) * $signed({1'b0, gain_q});
`endif
            wire signed [15:0] dizi_pre  = dizi_prod[25:10];  // == (main*gain_q) >>> 10

            reg signed [15:0] dizi_r;                        // frame_tick pipeline
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)          dizi_r <= 16'sd0;
                else if (frame_tick) dizi_r <= dizi_pre;
            end

            // ---- the 3:1 timbre mux (NO test_mode term -- see the header) ----
            // |main + harm| <= 43678, which is why voice_samp is 18 bit: the sum
            // is formed in 18-bit signed and therefore cannot wrap.
            wire signed [17:0] main_ext = {{2{main_samp[15]}}, main_samp};
            wire signed [17:0] harm_ext = {{2{harm_r[15]}},    harm_r};
            wire signed [17:0] dizi_ext = {{2{dizi_r[15]}},    dizi_r};
            wire signed [17:0] voice_mix = (timbre_hold == TIMBRE_GUZHENG) ? (main_ext + harm_ext) :
                                           (timbre_hold == TIMBRE_DIZI)     ? dizi_ext           :
                                                                              main_ext;

            // W5 (Task-017): the SubTask-012-A SIM-ONLY force -> volume point
            // (force_atten / FORCE_SIM_ENABLE / note_g == 5) is DELETED. In the
            // delivery configuration that branch was already pruned (constant
            // false), so voice_samp is bit-identical to the bypass it replaces.
            assign voice_samp[g] = voice_mix;
        end
    endgenerate

    // ========================================================================
    // Notify voice (the 33rd independent voice): shares no phase or envelope
    // hardware with the pool, so a notification never disturbs a held chord.
    // ========================================================================
    wire [23:0] fcw_beep = notify_tone ? FCW_ATT : FCW_DONE;
    wire signed [15:0] beep_samp;

    synth_voice #(
        .SUSTAIN_LEVEL (21'd614)
    ) u_beep (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_pulse (frame_tick),
        .note_on      (notify_on),
        .note_off     (notify_off),
        .fcw          (fcw_beep),
        .sample_out   (beep_samp),
        .env          (),
        .active       ()
    );

    // Notify tone: attenuated by the SAME factor as the played notes, then x2
    // with saturation.
    //   The notify voice is a full-scale single oscillator. With the play path
    //   at /16, emitting it unscaled would make the prompt ~24 dB louder than a
    //   played note -- startling on a 3 W speaker, and it would drive the
    //   amplifier into clipping. Scaling it identically first preserves the
    //   original intent: "the prompt is twice the level of one note".
    //   Thresholds stay written as sized 16-bit signed literals so no implicit
    //   width conversion happens (they no longer trigger at /16, but keep the
    //   saturation guard in case PLAY_SHIFT is tuned back down).
    wire signed [15:0] beep_scaled = beep_samp >>> PLAY_SHIFT;
    wire        beep_pos = (beep_scaled >  16'sd16383);   // > +16383 -> x2 overflows
    wire        beep_neg = (beep_scaled <  16'shC000);    // < -16384 -> x2 overflows
    wire signed [15:0] beep_boost = beep_pos ? 16'sd32767 :   // saturate to +32767
                                    beep_neg ? 16'sh8000 :    // saturate to -32768
                                    {beep_scaled[14:0], 1'b0}; // x2 (shift left)

    // SubTask-006-B (Q7 ruling (C)), change 2: register the notify sample before
    // the output mux, so the saturate/x2 mux occupies its own pipeline stage
    // instead of sharing a cycle with the mix mux. Frame-transparent by
    // construction: beep_boost is built from beep_samp, whose upstream registers
    // (sine_gen's osc, adsr's env) are clocked by the same frame_tick
    // sample_pulse -- so beep_boost flips exactly ON the frame_tick edge, never
    // between the two edges the latch below spans. The latch therefore sees the
    // very value the unregistered mux would have supplied; only the path is
    // shorter. sine_gen.v is deliberately NOT touched (frozen read-only set).
    reg signed [15:0] beep_boost_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) beep_boost_r <= 16'sd0;
        else        beep_boost_r <= beep_boost;
    end

    // During a notification sequence only the notification sounds (the pool is
    // muted for the duration, exactly as in the AX515 original).
    wire signed [15:0] mix = notify_busy ? beep_boost_r : note_mix;

    // ---- frame latch: the I2S block must see one stable sample per frame ----
    // frame_tick is the frame boundary (WS flipping into RIGHT). The sum being
    // latched here was completed 1024-33 cycles earlier, so it is always the
    // finished previous frame; mix_frame then holds it for the whole next frame.
    reg signed [15:0] mix_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          mix_frame <= 16'sd0;
        else if (frame_tick) mix_frame <= mix;
    end

    // Muted until POR is done. Voices are IDLE with env = 0 after reset anyway,
    // so this is belt-and-braces silence at power-up.
    wire [15:0] sample_muted = tx_en ? mix_frame : 16'd0;

    // ========================================================================
    // Delay effect (Task-010 / SubTask-010-A) -- module in rtl/fx_delay.v
    // ========================================================================
    // New single-byte commands (L1 allocation; 0x01-0x05 keep their meaning):
    //   0x06 : toggle fx_enable
    //   0x07 : delay_sel 00 -> 01 -> 10 -> 11 -> 00  (30 / 45 / 60 / 150 ms)
    // Both registers live in the existing clk domain. I2S only samples on
    // frame_tick, so a command takes effect at the next frame boundary (the
    // one after it if it lands on the boundary itself): no frame already
    // latched by pt8211_i2s_tx can be modified.
    //
    // Mounting point: AFTER the sequencer mix latch (sample_muted) and BEFORE
    // pt8211_i2s_tx. lat_detect below still observes `mix`, so the Task-007
    // observation chain is untouched and is NOT wrapped by the effect.
    //
    // Bypass is bit-exact: fx_delay's output mux is a combinational mux on
    // sample_in; it has no register, so enable = 0 adds no frame of delay.
    wire uart_fx_toggle = (rx_done_eff && (rx_data == 8'h06)) || ev_fx_toggle;
    wire uart_dly_step  = (rx_done_eff && (rx_data == 8'h07)) || ev_dly_step;

    reg        fx_enable;
    reg  [1:0] delay_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fx_enable <= 1'b0;          // delivery default: effect OFF
            delay_sel <= 2'd0;          // 30 ms
        end else begin
            if (uart_fx_toggle)
                fx_enable <= ~fx_enable;
            if (uart_dly_step)
                delay_sel <= (delay_sel == 2'd0) ? 2'd1 :
                             (delay_sel == 2'd1) ? 2'd2 :
                             (delay_sel == 2'd2) ? 2'd3 : 2'd0;
        end
    end

    wire [15:0] sample_fx;

    fx_delay u_fx_delay (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .sample_in  (sample_muted),
        .enable     (fx_enable),
        .delay_sel  (delay_sel),
        .sample_out (sample_fx)
    );

    // ========================================================================
    // Reverb effect (L1 W10, 2026-10-25) -- module in rtl/fx_reverb.v
    // ========================================================================
    // Mounted IN SERIES after fx_delay, so the whole W9 chain is preserved
    // verbatim:
    //   sample_muted -> fx_delay -> fx_reverb -> sample_l/r -> pt8211_i2s_tx
    //
    // New single-byte commands (work order W10 section 五):
    //   0x0C : toggle rev_enable           (delivery default OFF)
    //   0x0D : room  0 -> 1 -> 2 -> 0      (g = 0.500 / 0.750 / 0.875)
    //   0x0E : damp  0 -> 1 -> 2 -> 3 -> 0 (damping lowpass intensity)
    // Same decode pattern as 0x06/0x07: rx_done_eff-gated, honoured in test
    // mode too, and effective from the sample after the byte.  The 2-bit
    // registers are consumed ONCE per sample at the reverb's compute edge
    // (rv_s2, see fx_reverb header) and each changes in a single atomic NB
    // update, so no sample can observe a mixed value.
    //
    // Bypass is bit-exact: fx_reverb's output mux is combinational on
    // sample_in, so with rev_enable = 0 sample_l/r === the W9 sample_fx and
    // every 198 anchor is untouched.  fx_reverb finishes a sample 8 clk
    // after the frame_tick edge (pipeline in its header), ~1016 clk before
    // pt8211 latches at the next frame boundary -> ZERO extra audio-frame
    // latency relative to the W9 chain.
    wire uart_rev_toggle = (rx_done_eff && (rx_data == 8'h0C));
    wire uart_rev_room   = (rx_done_eff && (rx_data == 8'h0D)) || ev_rv_room;
    wire uart_rev_damp   = (rx_done_eff && (rx_data == 8'h0E)) || ev_rv_damp;
    wire uart_rev_step   = uart_rev_toggle || ev_rev;   // screen REV key steps
                                                        // the same 4-state view

    reg        rev_enable;
    reg  [1:0] rev_room;
    reg  [1:0] rev_damp;

    // rev_state is the single DISPLAY view both entrances act on:
    //   0 = OFF, 1 = R0 (g=0.500), 2 = R1 (0.750), 3 = R2 (0.875).
    // It is DERIVED from the two storage regs, so the PC 0x0C toggle keeps its
    // exact pre-W10-screen semantics (pure on/off, room preserved) and the
    // screen REV key walks OFF -> R0 -> R1 -> R2 -> OFF from wherever it is.
    wire [1:0] rev_state_v = rev_enable ? (rev_room + 2'd1) : 2'd0;
    wire [1:0] rev_step_nx = (rev_state_v == 2'd3) ? 2'd0 : (rev_state_v + 2'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rev_enable <= 1'b0;         // W10 delivery default: reverb OFF
            rev_room   <= 2'd0;         // g = 0.500 (small room)
            rev_damp   <= 2'd0;         // damping off
        end else begin
            if (uart_rev_toggle)
                rev_enable <= ~rev_enable;          // PC 0x0C: room preserved
            if (ev_rev) begin                       // screen key: 4-step cycle
                rev_enable <= (rev_step_nx != 2'd0);
                rev_room   <= (rev_step_nx != 2'd0) ? (rev_step_nx - 2'd1)
                                                    : rev_room;
            end
            if (uart_rev_room)
                rev_room <= (rev_room == 2'd2) ? 2'd0 : (rev_room + 2'd1);
            if (uart_rev_damp)
                rev_damp <= (rev_damp == 2'd3) ? 2'd0 : (rev_damp + 2'd1);
        end
    end

    wire [15:0] sample_rev;

    fx_reverb u_fx_reverb (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .sample_in  (sample_fx),
        .enable     (rev_enable),
        .room_sel   (rev_room),
        .damp_sel   (rev_damp),
        .sample_out (sample_rev)
    );

    // ========================================================================
    // W20 (2026-10-29): CHORUS -- modulated short delay, after fx_reverb
    // ------------------------------------------------------------------------
    // Chain order: fx_reverb -> fx_chorus -> fx_tremolo -> I2S.
    // fx_chorus captures sample_in at clk#10 (reverb's mix_out is registered at
    // E9 = clk#9) and registers its mixed result at clk#15, all inside the same
    // frame, so the enabled path adds ZERO audio frames of latency.
    // enable = 0 : pure combinational bypass, bit-exact vs F1.
    // Control: PC byte 0x11 toggles chorus; byte 0x12 toggles mix 3/4:1/4 <-> 1/2:1/2.
    // Screen-W21: page-1 CHORUS key (obj 15) ORs into the 0x11 toggle only;
    // 0x12 (cho_mix) has no screen key and stays PC-only.
    // ========================================================================
`ifdef W20_CHORUS
    wire uart_chorus  = (rx_done_eff && (rx_data == 8'h11)) || ev_chorus;
    wire uart_cho_mix = (rx_done_eff && (rx_data == 8'h12)) || ev_cho_mix;
    reg  cho_en;
    reg  cho_mix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cho_en  <= 1'b0;
            cho_mix <= 1'b0;
        end else begin
            if (uart_chorus)  cho_en  <= ~cho_en;
            if (uart_cho_mix) cho_mix <= ~cho_mix;
        end
    end
`endif
    // With W20_CHORUS undefined there is NO 0x11/0x12 decode at all: the
    // bytes are simply ignored by the command decoder (no residue).

    // W20 build batching (2026-10-29): the chorus is compiled in only when
    // W20_CHORUS is defined. Batch 1 (glide+tremolo) leaves it out because the
    // combined netlist made Gowin routing phase 0 stall >25 min; the chorus gets
    // its own build slot so each bitstream has a clean, comparable gate record.
`ifdef W20_CHORUS
    wire [15:0] sample_chorus;
    fx_chorus u_fx_chorus (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .sample_in  (sample_rev),
        .enable     (cho_en),
        .mix_sel    (cho_mix),
        .sample_out (sample_chorus)
    );
    wire [15:0] chain_in = sample_chorus;
    localparam integer TREM_CAP = 16;   // chorus result lands at clk#15
`else
    wire [15:0] chain_in = sample_rev;
    localparam integer TREM_CAP = 10;   // reverb result lands at clk#9
`endif

    // ========================================================================
    // W20 (2026-10-29): TREMOLO -- independent AMPLITUDE expression dimension
    // ------------------------------------------------------------------------
    // Placed AFTER fx_reverb (so it modulates the whole wet+dry result, the most
    // audible placement) and BEFORE the I2S latch. fx_tremolo samples its input
    // at clk#10 and registers its result at clk#11, both inside the SAME frame,
    // so the enabled path adds ZERO audio frames of latency; the I2S E1 latch
    // point is untouched.
    //
    // depth_sel = 0 : pure combinational bypass, bit-exact vs F1.
    // depth_sel = 1/2/3 : -1/8, -1/4, -1/2 peak amplitude modulation at the
    //                    shared 5.5006 Hz LFO (same LFO as the pitch vibrato,
    //                    independent depth -- the two controls are separate, so
    //                    "pitch wobble" and "volume swell" can be demonstrated
    //                    one at a time).
    // Control: PC single byte 0x10 cycles 0->1->2->3->0.
    // Screen-W21: page-1 TREM key (obj 14) ORs in and walks the same cycle.
    // ========================================================================
    wire uart_trem = (rx_done_eff && (rx_data == 8'h10)) || ev_trem;
    reg  [1:0] trem_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            trem_sel <= 2'd0;
        else if (uart_trem)
            trem_sel <= (trem_sel == 2'd3) ? 2'd0 : (trem_sel + 2'd1);
    end

    wire [15:0] sample_trem;
    fx_tremolo #(.CAP_SLOT(TREM_CAP)) u_fx_trem (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .sample_in  (chain_in),
        .depth_sel  (trem_sel),
        .lfo_samp   (lfo_samp),
        .sample_out (sample_trem)
    );

    // D2: sample_l/sample_r are driven by u_fx_ddr_echo at the end of this file.

    // ========================================================================
    // Latency observer (Task-007) -- see the file header section of this name
    // ========================================================================
    // PURELY OBSERVATIONAL. Read-only taps: key_on[12] / key_on[3] (the two
    // keys LAT1/LAT2 press) and `mix` (the value the frame latch above is
    // consuming at this very edge). Nothing below drives any existing signal,
    // no port is added, and the mix data path is unchanged.
    //
    // Anchor (identical in the TB): the event edge is the frame_tick edge whose
    // PRE-EDGE |mix| first crosses LAT_THRESH; lat_cnt at that edge is the
    // number of clk periods from the key_on pulse edge to it. lat_cnt HOLDS the
    // event value afterwards, so it IS lat_cycles -- there is no second latch.
    //
    // mix is already declared above (notify_busy ? beep_boost_r : note_mix).
    // The 3-bit signed literal is written as 16'sd256 so the comparison below is
    // signed: an unsigned compare would make every negative sample "> 256".
    localparam signed [15:0] LAT_THRESH = 16'sd256;   // |mix| > 256, strict

    (* syn_preserve = "true" *) reg [19:0] lat_cnt;    // 20 FF: cycles since start
    (* syn_preserve = "true" *) reg [19:0] lat_max;    // 20 FF: largest run so far
    (* syn_preserve = "true" *) reg        lat_busy;   //  1 FF: the FSM state

    wire lat_start  = key_on[12] | key_on[3];      // either LAT1 or LAT2 key
    wire lat_detect = frame_tick && ((mix > LAT_THRESH) || (mix < -LAT_THRESH));
    wire [19:0] lat_next = lat_cnt + 20'd1;        // combinational incrementer

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_cnt  <= 20'd0;
            lat_max  <= 20'd0;
            lat_busy <= 1'b0;                      // reset: IDLE
        end else if (!lat_busy) begin
            // ---------------- IDLE: wait for a start edge --------------------
            if (lat_start) begin
                lat_cnt  <= 20'd0;                 // start of measurement clears
                lat_busy <= 1'b1;                  // -> ARMED
            end
        end else begin
            // ---------------- ARMED: count, or latch on the event -----------
            if (lat_start) begin
                // Same-cycle competition: START WINS -> this edge begins a new
                // run, the count restarts from 0 and we stay ARMED.
                lat_cnt <= 20'd0;
            end else begin
                lat_cnt <= lat_next;               // one clk period per cycle
                if (lat_detect) begin
                    // The count above already includes the cycle that ends at
                    // this edge, so lat_next == cycles(start edge -> this edge).
                    lat_busy <= 1'b0;              // -> IDLE: count stops, holds
                    if (lat_next > lat_max)        // only ever grows
                        lat_max <= lat_next;
                end
            end
        end
    end

    // ========================================================================
    // U15 UART export (SubTask-007-C) -- read-only tap on the observer above
    // ========================================================================
    // The 41-FF lat_test observer (lat_cnt / lat_max / lat_busy, with their
    // syn_preserve attributes) is NOT modified. This block only observes its
    // completion edge and copies the already-updated 20-bit values:
    //
    //   E0 : lat_busy 1 -> 0, lat_cnt / lat_max updated (observer edge).
    //   E1 : lat_exp_busy_d = 1, lat_busy = 0 -> snapshot lat_cnt / lat_max.
    //
    // Sampling at E1 with non-blocking reads takes PRE-edge values, so a new
    // measurement starting on E1 can never leak a zero into the snapshot, and
    // the snapshot is exactly the value E0 latched (no +1 bias).
    //
    // Queue: one active snapshot (the frame being sent) + one pending
    // snapshot. If a completion lands on the same edge that IDLE consumes the
    // pending item, the OLD pending value moves to the active position and the
    // new value goes into the freed pending slot (no overwrite, no reorder).
    // A completion while the pending slot is still occupied sets
    // lat_exp_overflow, a probe flag that must stay 0 in every accepted run.
    //
    // LATRDY has first-frame priority and is sent exactly once after POR;
    // measurements completed during it wait in the pending slot. There is no
    // periodic LATRDY. START-wins competition inside the observer (same-cycle
    // lat_start + lat_detect) creates no completion edge, hence no frame.
    //
    // Frames (ASCII, uppercase hex, fixed width):
    //   LATRDY\r\n                  8 bytes
    //   LAT=XXXXX MAX=XXXXX\r\n    21 bytes, byte 0..20 (CR at 19, LF at 20)
    // 1 clk = 20 ns; 115200 8N1, DIV = 434 (50 MHz / 115200).
    // ========================================================================
    localparam [2:0] LAT_EXP_S_IDLE        = 3'd0,
                     LAT_EXP_S_PREPARE     = 3'd1,
                     LAT_EXP_S_ISSUE       = 3'd2,
                     LAT_EXP_S_WAIT_ACCEPT = 3'd3,
                     LAT_EXP_S_WAIT_DONE   = 3'd4;

    localparam [4:0] LAT_EXP_MEAS_LAST = 5'd20;   // last byte of a measurement
    localparam [4:0] LAT_EXP_RDY_LAST  = 5'd7;    // last byte of LATRDY\r\n

    reg        lat_exp_busy_d;             // observer busy, one clk delayed
    reg [19:0] lat_exp_active_cnt;         // snapshot being transmitted
    reg [19:0] lat_exp_active_max;
    reg [19:0] lat_exp_pending_cnt;        // one-deep waiting snapshot
    reg [19:0] lat_exp_pending_max;
    reg        lat_exp_pending_valid;
    reg        lat_exp_ready_pending;      // LATRDY not sent yet
    reg        lat_exp_frame_kind;         // 0 = measurement, 1 = LATRDY
    reg [2:0]  lat_exp_state;
    reg [4:0]  lat_exp_byte_idx;
    reg        lat_exp_tx_send;            // one-clk request to uart_tx
    reg        lat_exp_overflow;           // probe: must stay 0

    wire       lat_exp_capture = lat_exp_busy_d && !lat_busy;   // E1
    wire       lat_exp_tx_busy;
    wire       lat_exp_tx_txd;
    reg  [7:0] lat_exp_tx_data;            // combinational char mux

    // Uppercase ASCII hex nibble. Pure logic mapping: no divider, no ROM.
    function [7:0] lat_exp_hex;
        input [3:0] v;
        begin
            if (v < 4'd10) lat_exp_hex = 8'h30 + {4'd0, v};
            else           lat_exp_hex = 8'h37 + {4'd0, v};   // 'A'..'F'
        end
    endfunction

    // Current byte of the active frame. byte_idx only advances after the TX
    // accepted AND completed the previous byte, so this stays stable through
    // PREPARE / ISSUE / WAIT_ACCEPT.
    always @* begin
        lat_exp_tx_data = 8'h00;
        if (lat_exp_frame_kind) begin
            case (lat_exp_byte_idx)
                5'd0: lat_exp_tx_data = 8'h4C;   // 'L'
                5'd1: lat_exp_tx_data = 8'h41;   // 'A'
                5'd2: lat_exp_tx_data = 8'h54;   // 'T'
                5'd3: lat_exp_tx_data = 8'h52;   // 'R'
                5'd4: lat_exp_tx_data = 8'h44;   // 'D'
                5'd5: lat_exp_tx_data = 8'h59;   // 'Y'
                5'd6: lat_exp_tx_data = 8'h0D;   // CR
                5'd7: lat_exp_tx_data = 8'h0A;   // LF
                default: lat_exp_tx_data = 8'h00;
            endcase
        end else begin
            case (lat_exp_byte_idx)
                5'd0:  lat_exp_tx_data = 8'h4C;  // 'L'
                5'd1:  lat_exp_tx_data = 8'h41;  // 'A'
                5'd2:  lat_exp_tx_data = 8'h54;  // 'T'
                5'd3:  lat_exp_tx_data = 8'h3D;  // '='
                5'd4:  lat_exp_tx_data = lat_exp_hex(lat_exp_active_cnt[19:16]);
                5'd5:  lat_exp_tx_data = lat_exp_hex(lat_exp_active_cnt[15:12]);
                5'd6:  lat_exp_tx_data = lat_exp_hex(lat_exp_active_cnt[11:8]);
                5'd7:  lat_exp_tx_data = lat_exp_hex(lat_exp_active_cnt[7:4]);
                5'd8:  lat_exp_tx_data = lat_exp_hex(lat_exp_active_cnt[3:0]);
                5'd9:  lat_exp_tx_data = 8'h20;  // ' '
                5'd10: lat_exp_tx_data = 8'h4D;  // 'M'
                5'd11: lat_exp_tx_data = 8'h41;  // 'A'
                5'd12: lat_exp_tx_data = 8'h58;  // 'X'
                5'd13: lat_exp_tx_data = 8'h3D;  // '='
                5'd14: lat_exp_tx_data = lat_exp_hex(lat_exp_active_max[19:16]);
                5'd15: lat_exp_tx_data = lat_exp_hex(lat_exp_active_max[15:12]);
                5'd16: lat_exp_tx_data = lat_exp_hex(lat_exp_active_max[11:8]);
                5'd17: lat_exp_tx_data = lat_exp_hex(lat_exp_active_max[7:4]);
                5'd18: lat_exp_tx_data = lat_exp_hex(lat_exp_active_max[3:0]);
                5'd19: lat_exp_tx_data = 8'h0D;  // CR
                5'd20: lat_exp_tx_data = 8'h0A;  // LF
                default: lat_exp_tx_data = 8'h00;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_exp_busy_d        <= 1'b0;
            lat_exp_active_cnt    <= 20'd0;
            lat_exp_active_max    <= 20'd0;
            lat_exp_pending_cnt   <= 20'd0;
            lat_exp_pending_max   <= 20'd0;
            lat_exp_pending_valid <= 1'b0;
            lat_exp_ready_pending <= 1'b1;      // LATRDY is the first frame
            lat_exp_frame_kind    <= 1'b1;
            lat_exp_state         <= LAT_EXP_S_IDLE;
            lat_exp_byte_idx      <= 5'd0;
            lat_exp_tx_send       <= 1'b0;
            lat_exp_overflow      <= 1'b0;
        end else begin
            lat_exp_busy_d  <= lat_busy;
            lat_exp_tx_send <= 1'b0;            // default: one-clk pulse only

            // ---------------- transmit FSM --------------------------------
            case (lat_exp_state)
                LAT_EXP_S_IDLE: begin
                    if (lat_exp_ready_pending) begin
                        lat_exp_ready_pending <= 1'b0;
                        lat_exp_frame_kind    <= 1'b1;
                        lat_exp_byte_idx      <= 5'd0;
                        lat_exp_state         <= LAT_EXP_S_PREPARE;
                    end else if (lat_exp_pending_valid) begin
                        lat_exp_active_cnt    <= lat_exp_pending_cnt;
                        lat_exp_active_max    <= lat_exp_pending_max;
                        lat_exp_pending_valid <= 1'b0;   // may refill below
                        lat_exp_frame_kind    <= 1'b0;
                        lat_exp_byte_idx      <= 5'd0;
                        lat_exp_state         <= LAT_EXP_S_PREPARE;
                    end
                end
                LAT_EXP_S_PREPARE: begin
                    if (!lat_exp_tx_busy)
                        lat_exp_state <= LAT_EXP_S_ISSUE;
                end
                LAT_EXP_S_ISSUE: begin
                    lat_exp_tx_send <= 1'b1;         // exactly one clk
                    lat_exp_state   <= LAT_EXP_S_WAIT_ACCEPT;
                end
                LAT_EXP_S_WAIT_ACCEPT: begin
                    if (lat_exp_tx_busy)             // TX latched the byte
                        lat_exp_state <= LAT_EXP_S_WAIT_DONE;
                end
                LAT_EXP_S_WAIT_DONE: begin
                    if (!lat_exp_tx_busy) begin      // stop bit finished
                        if (lat_exp_byte_idx ==
                            (lat_exp_frame_kind ? LAT_EXP_RDY_LAST
                                                : LAT_EXP_MEAS_LAST)) begin
                            lat_exp_byte_idx <= 5'd0;
                            lat_exp_state    <= LAT_EXP_S_IDLE;
                        end else begin
                            lat_exp_byte_idx <= lat_exp_byte_idx + 5'd1;
                            lat_exp_state    <= LAT_EXP_S_PREPARE;
                        end
                    end
                end
                default: lat_exp_state <= LAT_EXP_S_IDLE;
            endcase

            // ---------------- completion capture (E1) ---------------------
            // Placed AFTER the consume above: a capture on the exact edge
            // that IDLE frees the pending slot lands in that freed slot.
            if (lat_exp_capture) begin
                if (!lat_exp_pending_valid ||
                    (lat_exp_state == LAT_EXP_S_IDLE &&
                     !lat_exp_ready_pending && lat_exp_pending_valid)) begin
                    lat_exp_pending_cnt   <= lat_cnt;
                    lat_exp_pending_max   <= lat_max;
                    lat_exp_pending_valid <= 1'b1;
                end else begin
                    lat_exp_overflow <= 1'b1;    // capacity violation (probe)
                end
            end
        end
    end

    // ========================================================================
    // SubTask-014-A guide engine (014 new region: every signal is guide_*)
    // ========================================================================
    // Preset-score ROM + dual-slot grouped follow-along judgment + screen text.
    // The audio path is untouched: key_on is only observed, never gated.
    // The LAT observer/export above is frozen; this block only consumes
    // frame_tick/key_on/rx_done and drives the 014 UART adapter below.
    // ========================================================================
    localparam [2:0] GUIDE_S_OFF        = 3'd0,
                     GUIDE_S_ENTER      = 3'd1,
                     GUIDE_S_FETCH      = 3'd2,
                     GUIDE_S_ACTIVE     = 3'd3,
                     GUIDE_S_DONE_DRAIN = 3'd4,
                     GUIDE_S_DONE_HOLD  = 3'd5,
                     GUIDE_S_EXIT_DRAIN = 3'd6,
                     GUIDE_S_EXIT_HOLD  = 3'd7;

    localparam [2:0] GUIDE_K_NONE   = 3'd0,
                     GUIDE_K_GREEN  = 3'd1,
                     GUIDE_K_GRAY   = 3'd2,
                     GUIDE_K_RED    = 3'd3,
                     GUIDE_K_STATUS = 3'd4,
                     GUIDE_K_DONE   = 3'd5,
                     GUIDE_K_IDLE   = 3'd6;

    localparam [4:0] GUIDE_F_IDX0_REQ = 5'd0,
                     GUIDE_F_IDX0_CAP = 5'd1,
                     GUIDE_F_IDX1_REQ = 5'd2,
                     GUIDE_F_IDX1_CAP = 5'd3,
                     GUIDE_F_N0_REQ0  = 5'd4,
                     GUIDE_F_N0_CAP0  = 5'd5,
                     GUIDE_F_N0_REQ1  = 5'd6,
                     GUIDE_F_N0_CAP1  = 5'd7,
                     GUIDE_F_N0_REQ2  = 5'd8,
                     GUIDE_F_N0_CAP2  = 5'd9,
                     GUIDE_F_N1_REQ0  = 5'd10,
                     GUIDE_F_N1_CAP0  = 5'd11,
                     GUIDE_F_N0B_REQ0 = 5'd12,
                     GUIDE_F_N0B_CAP0 = 5'd13,
                     GUIDE_F_N1_REQ1  = 5'd14,
                     GUIDE_F_N1_CAP1  = 5'd15,
                     GUIDE_F_N0B_REQ1 = 5'd16,
                     GUIDE_F_N0B_CAP1 = 5'd17,
                     GUIDE_F_N1_REQ2  = 5'd18,
                     GUIDE_F_N1_CAP2  = 5'd19,
                     GUIDE_F_READY    = 5'd20,
                     GUIDE_F_START    = 5'd21;

    localparam [17:0] GUIDE_TICKS_2S   = 18'd97656,   // 2 s at Fs
                      GUIDE_TICKS_5S   = 18'd244141,  // 5 s at Fs
                      GUIDE_TICKS_RED  = 18'd4883;    // ~100 ms red hold

    localparam [1:0] GUIDE_UART_IDLE        = 2'd0,
                     GUIDE_UART_ISSUE       = 2'd1,
                     GUIDE_UART_WAIT_ACCEPT = 2'd2,
                     GUIDE_UART_WAIT_DONE   = 2'd3;

    localparam [1:0] FX_UART_OWN_NONE = 2'd0,
                     FX_UART_OWN_LAT  = 2'd1,
                     FX_UART_OWN_SCR  = 2'd2;

    // ---------------- decimal / name / frame text helpers ----------------
    // All values used by this score are 0..60, so one or two digits suffice.
    function [3:0] guide_digits;
        input [7:0] v;
        begin
            guide_digits = (v >= 8'd10) ? 4'd2 : 4'd1;
        end
    endfunction

    function [3:0] guide_tens;
        input [7:0] v;
        integer t;
        begin
            if      (v >= 8'd60) t = 6;
            else if (v >= 8'd50) t = 5;
            else if (v >= 8'd40) t = 4;
            else if (v >= 8'd30) t = 3;
            else if (v >= 8'd20) t = 2;
            else if (v >= 8'd10) t = 1;
            else                 t = 0;
            guide_tens = t[3:0];
        end
    endfunction

    function [3:0] guide_ones;
        input [7:0] v;
        reg [3:0] t;
        reg [7:0] t10;
        begin
            t = guide_tens(v);
            // t is 0..6, so t*10 = (t<<3) + (t<<1): shift-add only, no 12x12
            // multiplier and therefore no DSP hard block. Displayed value is
            // unchanged (same tens/ones split for 0..60).
            t10 = ({4'd0, t} << 3) + ({4'd0, t} << 1);
            guide_ones = v - t10;
        end
    endfunction

    function [3:0] guide_name_len;
        input [1:0] song;
        begin
            if      (song == 2'd0) guide_name_len = 4'd7;   // Twinkle
            else if (song == 2'd1) guide_name_len = 4'd3;   // Ode
            else                   guide_name_len = 4'd8;   // Farewell
        end
    endfunction

    function [7:0] guide_name_char;
        input [1:0] song;
        input [3:0] off;
        begin
            guide_name_char = 8'h20;
            if (song == 2'd0) begin
                case (off)
                    4'd0: guide_name_char = 8'h54; // T
                    4'd1: guide_name_char = 8'h77; // w
                    4'd2: guide_name_char = 8'h69; // i
                    4'd3: guide_name_char = 8'h6E; // n
                    4'd4: guide_name_char = 8'h6B; // k
                    4'd5: guide_name_char = 8'h6C; // l
                    4'd6: guide_name_char = 8'h65; // e
                    default: guide_name_char = 8'h20;
                endcase
            end else if (song == 2'd1) begin
                case (off)
                    4'd0: guide_name_char = 8'h4F; // O
                    4'd1: guide_name_char = 8'h64; // d
                    4'd2: guide_name_char = 8'h65; // e
                    default: guide_name_char = 8'h20;
                endcase
            end else begin
                case (off)
                    4'd0: guide_name_char = 8'h46; // F
                    4'd1: guide_name_char = 8'h61; // a
                    4'd2: guide_name_char = 8'h72; // r
                    4'd3: guide_name_char = 8'h65; // e
                    4'd4: guide_name_char = 8'h77; // w
                    4'd5: guide_name_char = 8'h65; // e
                    4'd6: guide_name_char = 8'h6C; // l
                    4'd7: guide_name_char = 8'h6C; // l
                    default: guide_name_char = 8'h20;
                endcase
            end
        end
    endfunction

    function [7:0] guide_color_char;
        input [2:0] kind;
        input [3:0] off;
        begin
            guide_color_char = 8'h30;
            if (kind == GUIDE_K_GREEN) begin
                case (off)                       // 2016
                    4'd0: guide_color_char = 8'h32;
                    4'd1: guide_color_char = 8'h30;
                    4'd2: guide_color_char = 8'h31;
                    4'd3: guide_color_char = 8'h36;
                    default: guide_color_char = 8'h20;
                endcase
            end else if (kind == GUIDE_K_GRAY) begin
                case (off)                       // 33808
                    4'd0: guide_color_char = 8'h33;
                    4'd1: guide_color_char = 8'h33;
                    4'd2: guide_color_char = 8'h38;
                    4'd3: guide_color_char = 8'h30;
                    4'd4: guide_color_char = 8'h38;
                    default: guide_color_char = 8'h20;
                endcase
            end else begin
                case (off)                       // 63488
                    4'd0: guide_color_char = 8'h36;
                    4'd1: guide_color_char = 8'h33;
                    4'd2: guide_color_char = 8'h34;
                    4'd3: guide_color_char = 8'h38;
                    4'd4: guide_color_char = 8'h38;
                    default: guide_color_char = 8'h20;
                endcase
            end
        end
    endfunction

    function [5:0] guide_frame_len_f;
        input [2:0] kind;
        input [3:0] key;              // key index 0..11 (NOT the object id)
        input [1:0] song;
        input [7:0] count;
        input [7:0] prog;
        input [7:0] score;
        reg [5:0] kd_extra, count_extra, prog_extra, score_extra;
        reg [4:0] kobj;               // page-0 lamp object id 7..18
        begin
            // page-0 lamps are NAME bt0..bt11 (user-confirmed 2026-11-01), so the
            // emitted suffix is the key index; digit count (0..9 = 1 digit,
            // 10..11 = 2 digits).
            kobj = {1'b0, key} + 5'd0;
            kd_extra = {5'd0, (kobj >= 5'd10)};
            count_extra = {5'd0, (count >= 8'd10)};
            prog_extra = {5'd0, (prog >= 8'd10)};
            score_extra = {5'd0, (score >= 8'd10)};
            case (kind)
                GUIDE_K_GREEN:  guide_frame_len_f = 6'd15 + kd_extra;
                GUIDE_K_GRAY,
                GUIDE_K_RED:    guide_frame_len_f = 6'd16 + kd_extra;
                GUIDE_K_STATUS: guide_frame_len_f = 6'd18 + {2'd0, guide_name_len(song)}
                                                    + prog_extra + count_extra + score_extra;
                GUIDE_K_DONE:   guide_frame_len_f = 6'd19 + score_extra;
                GUIDE_K_IDLE:   guide_frame_len_f = 6'd16;
                default:        guide_frame_len_f = 6'd0;
            endcase
        end
    endfunction

    function [7:0] guide_frame_char_f;
        input [2:0] kind;
        input [4:0] pos;
        input [3:0] key;              // key index 0..11 (NOT the object id)
        input [1:0] song;
        input [7:0] count;
        input [7:0] prog;
        input [7:0] score;
        reg [4:0] off, q, nl, pd, nd, sd;
        reg [4:0] kobj;               // page-0 lamp object id 7..18
        reg [4:0] p_start, c_start, s_start, quote_pos;
        reg [7:0] ch, decimal_value;
        reg decimal_emit, decimal_tens;
        reg [3:0] decimal_digit;
        begin
            ch = 8'hFF;
            off = 5'd0;
            q = 5'd0;
            // page-0 lamps are NAME bt0..bt11 (user-confirmed 2026-11-01):
            kobj = {1'b0, key} + 5'd0;
            nl = {1'b0, guide_name_len(song)};
            pd = {1'b0, guide_digits(prog)};
            nd = {1'b0, guide_digits(count)};
            sd = {1'b0, guide_digits(score)};
            p_start = 5'd9 + nl;
            c_start = 5'd11 + nl + {4'd0, (prog >= 8'd10)};
            s_start = 5'd13 + nl + {4'd0, (prog >= 8'd10)}
                                + {4'd0, (count >= 8'd10)};
            quote_pos = s_start + sd;
            decimal_value = 8'd0;
            decimal_emit = 1'b0;
            decimal_tens = 1'b0;
            decimal_digit = 4'd0;

            if ((kind == GUIDE_K_GREEN) || (kind == GUIDE_K_GRAY) ||
                (kind == GUIDE_K_RED)) begin
                if (pos == 5'd0) ch = 8'h62;
                else if (pos == 5'd1) ch = 8'h74;
                else if (pos < (5'd3 + {4'd0, (kobj >= 5'd10)})) begin
                    if (kobj >= 5'd10)
                        ch = (pos == 5'd2) ? 8'h31 : (8'h30 + (kobj - 5'd10));
                    else ch = {3'h3, kobj};
                end else begin
                    off = pos - (5'd3 + {4'd0, (kobj >= 5'd10)});
                    case (off)
                        5'd0: ch = 8'h2E;
                        // W5 (Task-017): token is now "bt<key>.bco=<color>"
                        // (was ".pco"). bco = background colour -> the screen
                        // fills the WHOLE key cell, pco only recolours the text.
                        // Same 3-character length, frame length unchanged.
                        5'd1: ch = 8'h62;
                        5'd2: ch = 8'h63;
                        5'd3: ch = 8'h6F;
                        5'd4: ch = 8'h3D;
                        default: begin
                            if (off < ((kind == GUIDE_K_GREEN) ? 5'd9 : 5'd10))
                                ch = guide_color_char(kind, off - 5'd5);
                        end
                    endcase
                end
            end else if ((kind == GUIDE_K_STATUS) || (kind == GUIDE_K_DONE) ||
                         (kind == GUIDE_K_IDLE)) begin
                if (pos < 5'd8) begin
                    case (pos)
                        5'd0: ch = 8'h74;
                        5'd1: ch = 8'h30;
                        5'd2: ch = 8'h2E;
                        5'd3: ch = 8'h74;
                        5'd4: ch = 8'h78;
                        5'd5: ch = 8'h74;
                        5'd6: ch = 8'h3D;
                        5'd7: ch = 8'h22;
                    endcase
                end else begin
                    off = pos - 5'd8;
                    case (kind)
                        GUIDE_K_STATUS: begin
                            if (off < nl) ch = guide_name_char(song, off[3:0]);
                            else if (off == nl) ch = 8'h20;
                            else if ((pos == p_start) ||
                                     ((pd == 5'd2) && (pos == p_start + 5'd1))) begin
                                decimal_value = prog;
                                decimal_emit = 1'b1;
                                decimal_tens = (pd == 5'd2) && (pos == p_start);
                            end else if (pos == c_start - 5'd1) ch = 8'h2F;
                            else if ((pos == c_start) ||
                                     ((nd == 5'd2) && (pos == c_start + 5'd1))) begin
                                decimal_value = count;
                                decimal_emit = 1'b1;
                                decimal_tens = (nd == 5'd2) && (pos == c_start);
                            end else if (pos == s_start - 5'd1) ch = 8'h20;
                            else if ((pos == s_start) ||
                                     ((sd == 5'd2) && (pos == s_start + 5'd1))) begin
                                decimal_value = score;
                                decimal_emit = 1'b1;
                                decimal_tens = (sd == 5'd2) && (pos == s_start);
                            end else if (pos == quote_pos) ch = 8'h22;
                        end
                        GUIDE_K_DONE: begin
                            case (off)
                                5'd0: ch = 8'h44;
                                5'd1: ch = 8'h6F;
                                5'd2: ch = 8'h6E;
                                5'd3: ch = 8'h65;
                                5'd4: ch = 8'h21;
                                5'd5: ch = 8'h20;
                                default: begin
                                    q = off - 5'd6;
                                    if (q < sd) begin
                                        decimal_value = score;
                                        decimal_emit = 1'b1;
                                        decimal_tens = (sd == 5'd2 && q == 5'd0);
                                    end else if (q == sd) ch = 8'h22;
                                end
                            endcase
                        end
                        GUIDE_K_IDLE: begin
                            case (off)
                                5'd0: ch = 8'h49;
                                5'd1: ch = 8'h64;
                                5'd2: ch = 8'h6C;
                                5'd3: ch = 8'h65;
                                5'd4: ch = 8'h22;
                            endcase
                        end
                    endcase
                end
            end
            if (decimal_emit) begin
                decimal_digit = decimal_tens ? guide_tens(decimal_value)
                                             : guide_ones(decimal_value);
                ch = {4'h3, decimal_digit};
            end
            guide_frame_char_f = ch;
        end
    endfunction

    function [3:0] guide_low_key12;
        input [11:0] m;
        integer i;
        begin
            guide_low_key12 = 4'd0;
            for (i = 11; i >= 0; i = i - 1)
                if (m[i]) guide_low_key12 = i[3:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // 014-A core: command decode, state machine, ROM fetch, judgment
    // ------------------------------------------------------------------
    // The operating mode is derived from the FSM state; the target mode and
    // target song are latched from 0x08/0x09. A command therefore always has
    // priority over the judgment of the same audio frame. The 0x01..0x07
    // paths are untouched.

    reg [2:0]  guide_state;
    reg        guide_target_mode;
    reg [1:0]  guide_target_song;
    reg [1:0]  guide_song;

    // fetch / index
    reg [7:0]  guide_idx;
    reg [7:0]  guide_count;
    reg [8:0]  guide_start_addr;
    reg [6:0]  guide_count_lo;
    reg [4:0]  guide_fstep;
    reg [11:0] guide_tmp;              // note1 start slice, compared in two halves
    reg        guide_match_low;
    reg        guide_start_match;

    // dual-slot group
    reg [3:0]  guide_slot0_key;
    reg [3:0]  guide_slot1_key;
    reg        guide_slot0_done;
    reg        guide_slot1_done;
    reg        guide_slot1_valid;
    reg [15:0] guide_slot0_rem;
    reg [15:0] guide_slot1_rem;
    reg        guide_group2;
    reg        guide_group_last;

    // score / errors / timers
    reg [7:0]  guide_score;
    reg [7:0]  guide_progress;
    reg [15:0] guide_error;
    reg [17:0] guide_timer;

    // key events and hint requests
    reg [11:0] guide_key_pending;
    reg [1:0]  guide_green_pending;
    reg [11:0] guide_gray_pending;
    reg        guide_gray_all_req;
    reg [3:0]  guide_gray_sweep;
    reg        guide_red_pending;
    reg        guide_red_shown;
    reg [3:0]  guide_red_key;
    reg        guide_status_dirty;
    reg        guide_status_hold;
    reg        guide_done_req;
    reg        guide_idle_req;
    reg        guide_flush_soft;

    // Frame producer registers (written by the producer block below).
    reg [2:0]  guide_frame_kind;
    reg [3:0]  guide_frame_key;
    reg [4:0]  guide_frame_idx;
    reg [5:0]  guide_frame_len;
    reg        guide_frame_active;
    reg        guide_frame_started;
    reg        guide_frame_is_sweep;
    reg [7:0]  guide_frame_prog;
    reg [7:0]  guide_frame_score;
    reg [7:0]  guide_frame_count;
    reg [1:0]  guide_frame_song;
    reg        guide_frame_start_pulse;
    reg        guide_frame_done_pulse;

    // ROM port (song_rom is instantiated at the end of this region).
    wire [17:0] guide_rom_rd_data;
    wire        guide_rom_rd_valid;

    // ------------------------------------------------------------------
    // Command decode (declared after the registers it reads)
    // ------------------------------------------------------------------
    wire guide_cmd_08 = (rx_done_eff && (rx_data == 8'h08)) || ev_guide;
    wire guide_cmd_09 = (rx_done_eff && (rx_data == 8'h09)) || ev_song;

    wire guide_tgt_mode_nxt = guide_cmd_08 ? ~guide_target_mode :
                              guide_cmd_09 ? 1'b1 : guide_target_mode;

    wire [1:0] guide_tgt_song_nxt =
        guide_cmd_08 ? (guide_target_mode ? guide_target_song : 2'd0) :
        guide_cmd_09 ? (guide_target_mode ?
                        ((guide_target_song == 2'd2) ? 2'd0 :
                                                        guide_target_song + 2'd1)
                        : 2'd0) :
        guide_target_song;

    wire guide_mode_actual = (guide_state == GUIDE_S_ENTER)   ||
                             (guide_state == GUIDE_S_FETCH)   ||
                             (guide_state == GUIDE_S_ACTIVE)  ||
                             (guide_state == GUIDE_S_DONE_DRAIN) ||
                             (guide_state == GUIDE_S_DONE_HOLD);

    // ------------------------------------------------------------------
    // Judgment wires (combinational, valid in ACTIVE)
    // ------------------------------------------------------------------
    wire [11:0] guide_ev = guide_key_pending | key_on[11:0];

    wire guide_slot0_win = (!guide_slot0_done) && (guide_slot0_rem != 16'd0);
    wire guide_slot1_win = guide_slot1_valid && (!guide_slot1_done) &&
                           (guide_slot1_rem != 16'd0);

    wire [11:0] guide_slot0_mask = guide_slot0_win ?
                                   (12'd1 << guide_slot0_key) : 12'd0;
    wire [11:0] guide_slot1_mask = guide_slot1_win ?
                                   (12'd1 << guide_slot1_key) : 12'd0;
    wire [11:0] guide_valid_mask = guide_slot0_mask | guide_slot1_mask;
    wire [11:0] guide_wrong_mask = guide_ev & ~guide_valid_mask;

    wire guide_hit0 = guide_ev[guide_slot0_key] && guide_slot0_win;
    wire guide_hit1 = guide_ev[guide_slot1_key] && guide_slot1_win;
    wire guide_timeout0 = (!guide_slot0_done) && (guide_slot0_rem == 16'd0);
    wire guide_timeout1 = guide_slot1_valid && (!guide_slot1_done) &&
                          (guide_slot1_rem == 16'd0);
    wire guide_any_wrong = (guide_wrong_mask != 12'd0);

    wire [1:0] guide_err_inc = {1'b0, guide_any_wrong} +
                               {1'b0, guide_timeout0} +
                               {1'b0, guide_timeout1};
    wire [16:0] guide_err_sum = {1'b0, guide_error} + {15'd0, guide_err_inc};

    // Exact-tick events at the activation edge. Events captured while the
    // engine was in FETCH are deliberately not carried into the group.
    wire [11:0] guide_act_mask = (12'd1 << guide_slot0_key) |
                                 (guide_group2 ?
                                  (12'd1 << guide_slot1_key) : 12'd0);
    wire [11:0] guide_act_wrong = key_on[11:0] & ~guide_act_mask;
    wire guide_act_hit0 = key_on[guide_slot0_key];
    wire guide_act_hit1 = guide_group2 && key_on[guide_slot1_key];

    // ------------------------------------------------------------------
    // Key event capture: every clk, consumed exactly once per frame_tick
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            guide_key_pending <= 12'd0;
        else if (frame_tick)
            guide_key_pending <= 12'd0;          // this tick is in key_on
        else
            guide_key_pending <= guide_key_pending | key_on[11:0];
    end

    // ------------------------------------------------------------------
    // Core sequential logic
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            guide_state          <= GUIDE_S_OFF;
            guide_target_mode    <= 1'b0;
            guide_target_song    <= 2'd0;
            guide_song           <= 2'd0;
            guide_idx            <= 8'd0;
            guide_count          <= 8'd0;
            guide_start_addr     <= 9'd0;
            guide_count_lo       <= 7'd0;
            guide_fstep          <= GUIDE_F_IDX0_REQ;
            guide_tmp            <= 12'd0;
            guide_match_low      <= 1'b0;
            guide_start_match    <= 1'b0;
            guide_slot0_key      <= 4'd0;
            guide_slot1_key      <= 4'd0;
            guide_slot0_done     <= 1'b1;
            guide_slot1_done     <= 1'b1;
            guide_slot1_valid    <= 1'b0;
            guide_slot0_rem      <= 16'd0;
            guide_slot1_rem      <= 16'd0;
            guide_group2         <= 1'b0;
            guide_group_last     <= 1'b0;
            guide_score          <= 8'd0;
            guide_progress       <= 8'd0;
            guide_error          <= 16'd0;
            guide_timer          <= 18'd0;
            guide_green_pending  <= 2'd0;
            guide_gray_pending   <= 12'd0;
            guide_gray_all_req   <= 1'b0;
            guide_gray_sweep     <= 4'd0;
            guide_red_pending    <= 1'b0;
            guide_red_shown      <= 1'b0;
            guide_red_key        <= 4'd0;
            guide_status_dirty   <= 1'b0;
            guide_status_hold    <= 1'b1;
            guide_done_req       <= 1'b0;
            guide_idle_req       <= 1'b0;
            guide_flush_soft     <= 1'b0;
        end else begin
            guide_flush_soft <= 1'b0;

            // 1. latch the requested mode/song
            if (guide_cmd_08 || guide_cmd_09) begin
                guide_target_mode <= guide_tgt_mode_nxt;
                guide_target_song <= guide_tgt_song_nxt;
            end

            // 2. mode change or song change wins over this frame's events
            if (guide_tgt_mode_nxt &&
                ((!guide_mode_actual) || (guide_tgt_song_nxt != guide_song))) begin
                // enter / re-enter / song switch: full clear, gray all keys
                guide_state          <= GUIDE_S_ENTER;
                guide_song           <= guide_tgt_song_nxt;
                guide_idx            <= 8'd0;
                guide_count          <= 8'd0;
                guide_start_addr     <= 9'd0;
                guide_count_lo       <= 7'd0;
                guide_fstep          <= GUIDE_F_IDX0_REQ;
                guide_tmp            <= 12'd0;
                guide_match_low      <= 1'b0;
                guide_start_match    <= 1'b0;
                guide_slot0_key      <= 4'd0;
                guide_slot1_key      <= 4'd0;
                guide_slot0_done     <= 1'b1;
                guide_slot1_done     <= 1'b1;
                guide_slot1_valid    <= 1'b0;
                guide_slot0_rem      <= 16'd0;
                guide_slot1_rem      <= 16'd0;
                guide_group2         <= 1'b0;
                guide_group_last     <= 1'b0;
                guide_score          <= 8'd0;
                guide_progress       <= 8'd0;
                guide_error          <= 16'd0;
                guide_timer          <= 18'd0;
                guide_green_pending  <= 2'd0;
                guide_gray_pending   <= 12'd0;
                guide_gray_all_req   <= 1'b1;
                guide_gray_sweep     <= 4'd0;
                guide_red_pending    <= 1'b0;
                guide_red_shown      <= 1'b0;
                guide_status_dirty   <= 1'b1;
                guide_status_hold    <= 1'b0;
                // a Done already requested while in DONE_DRAIN is a
                // mandatory transaction: keep it so ENTER drains it first
                guide_idle_req       <= 1'b0;
                guide_flush_soft     <= 1'b1;
            end else if (!guide_tgt_mode_nxt && guide_mode_actual) begin
                // exit: stop judging at once, keep the final score visible,
                // drain the in-flight frame, then gray the whole keyboard
                guide_state          <= GUIDE_S_EXIT_DRAIN;
                guide_slot0_done     <= 1'b1;
                guide_slot1_done     <= 1'b1;
                guide_timer          <= 18'd0;
                guide_green_pending  <= 2'd0;
                guide_gray_pending   <= 12'd0;
                guide_gray_all_req   <= 1'b1;
                guide_gray_sweep     <= 4'd0;
                guide_red_pending    <= 1'b0;
                guide_red_shown      <= 1'b0;
                guide_status_hold    <= 1'b1;
                // keep an already-requested Done; EXIT_DRAIN waits for it
                guide_idle_req       <= 1'b0;
                guide_flush_soft     <= 1'b1;
            end else begin

                // 3. frame completion effects (last stop bit finished)
                if (guide_frame_done_pulse) begin
                    case (guide_frame_kind)
                        GUIDE_K_GRAY: begin
                            if (guide_frame_is_sweep) begin
                                if (guide_gray_sweep == 4'd11)
                                    guide_gray_all_req <= 1'b0;
                                else
                                    guide_gray_sweep <= guide_gray_sweep + 4'd1;
                                guide_gray_pending[guide_frame_key] <= 1'b0;
                            end else begin
                                guide_gray_pending[guide_frame_key] <= 1'b0;
                            end
                            if (guide_red_shown &&
                                (guide_red_key == guide_frame_key))
                                guide_red_shown <= 1'b0;
                        end
                        GUIDE_K_RED: begin
                            guide_red_shown <= 1'b1;
                            guide_timer     <= 18'd0;
                        end
                        GUIDE_K_DONE: guide_done_req <= 1'b0;
                        GUIDE_K_IDLE: guide_idle_req <= 1'b0;
                        default: ;
                    endcase
                end

                // 4. request consumption when a screen frame really starts
                if (guide_frame_start_pulse) begin
                    case (guide_frame_kind)
                        GUIDE_K_STATUS: begin
                            if ((guide_frame_prog == guide_progress) &&
                                (guide_frame_score == guide_score))
                                guide_status_dirty <= 1'b0;
                        end
                        GUIDE_K_GREEN: begin
                            if (guide_frame_key == guide_slot0_key)
                                guide_green_pending[0] <= 1'b0;
                            else if (guide_frame_key == guide_slot1_key)
                                guide_green_pending[1] <= 1'b0;
                        end
                        GUIDE_K_RED: guide_red_pending <= 1'b0;
                        default: ;
                    endcase
                end

                // 5. main FSM
                case (guide_state)

                    GUIDE_S_OFF: begin
                        // waiting for 0x08 / 0x09
                    end

                    GUIDE_S_ENTER: begin
                        // wait until nothing mandatory is still in flight
                        if (!guide_frame_active &&
                            (guide_gray_pending == 12'd0) &&
                            !guide_gray_all_req &&
                            !guide_done_req && !guide_idle_req) begin
                            guide_state <= GUIDE_S_FETCH;
                            guide_fstep <= GUIDE_F_IDX0_REQ;
                            guide_count <= 8'd0;
                        end
                    end

                    GUIDE_S_FETCH: begin
                        case (guide_fstep)
                            GUIDE_F_IDX0_REQ:
                                guide_fstep <= GUIDE_F_IDX0_CAP;

                            GUIDE_F_IDX0_CAP: begin
                                guide_start_addr <= guide_rom_rd_data[8:0];
                                guide_count_lo   <= guide_rom_rd_data[15:9];
                                guide_fstep      <= GUIDE_F_IDX1_REQ;
                            end

                            GUIDE_F_IDX1_REQ:
                                guide_fstep <= GUIDE_F_IDX1_CAP;

                            GUIDE_F_IDX1_CAP: begin
                                guide_count <= {guide_rom_rd_data[1:0],
                                                guide_count_lo};
                                guide_fstep <= GUIDE_F_START;
                            end

                            GUIDE_F_START: begin
                                if (guide_idx >= guide_count) begin
                                    // safety stop for an empty index
                                    guide_state        <= GUIDE_S_DONE_DRAIN;
                                    guide_done_req     <= 1'b1;
                                    guide_gray_all_req <= 1'b1;
                                    guide_gray_sweep   <= 4'd0;
                                    guide_gray_pending <= 12'd0;
                                    guide_green_pending<= 2'd0;
                                    guide_red_pending  <= 1'b0;
                                    guide_red_shown    <= 1'b0;
                                    guide_status_hold  <= 1'b1;
                                end else begin
                                    guide_fstep <= GUIDE_F_N0_REQ0;
                                end
                            end

                            GUIDE_F_N0_REQ0:
                                guide_fstep <= GUIDE_F_N0_CAP0;

                            GUIDE_F_N0_CAP0: begin
                                guide_slot0_key <= guide_rom_rd_data[3:0];
                                guide_fstep     <= GUIDE_F_N0_REQ1;
                            end

                            GUIDE_F_N0_REQ1:
                                guide_fstep <= GUIDE_F_N0_CAP1;

                            GUIDE_F_N0_CAP1: begin
                                guide_slot0_rem[6:0] <= guide_rom_rd_data[15:9];
                                guide_fstep          <= GUIDE_F_N0_REQ2;
                            end

                            GUIDE_F_N0_REQ2:
                                guide_fstep <= GUIDE_F_N0_CAP2;

                            GUIDE_F_N0_CAP2: begin
                                guide_slot0_rem[15:7] <= guide_rom_rd_data[8:0];
                                guide_slot1_valid     <= 1'b0;
                                guide_slot1_done      <= 1'b1;
                                guide_fstep           <= GUIDE_F_N1_REQ0;
                            end

                            // note1 key + start low; start is compared after
                            // a second read of note0 so no 21-bit copy is kept
                            GUIDE_F_N1_REQ0:
                                guide_fstep <= GUIDE_F_N1_CAP0;

                            GUIDE_F_N1_CAP0: begin
                                guide_slot1_key <= guide_rom_rd_data[3:0];
                                guide_tmp       <= guide_rom_rd_data[15:4];
                                guide_fstep     <= GUIDE_F_N0B_REQ0;
                            end

                            GUIDE_F_N0B_REQ0:
                                guide_fstep <= GUIDE_F_N0B_CAP0;

                            GUIDE_F_N0B_CAP0: begin
                                guide_match_low <= (guide_rom_rd_data[15:4] ==
                                                    guide_tmp);
                                guide_fstep     <= GUIDE_F_N1_REQ1;
                            end

                            GUIDE_F_N1_REQ1:
                                guide_fstep <= GUIDE_F_N1_CAP1;

                            GUIDE_F_N1_CAP1: begin
                                guide_tmp[8:0]       <= guide_rom_rd_data[8:0];
                                guide_slot1_rem[6:0] <= guide_rom_rd_data[15:9];
                                guide_fstep          <= GUIDE_F_N0B_REQ1;
                            end

                            GUIDE_F_N0B_REQ1:
                                guide_fstep <= GUIDE_F_N0B_CAP1;

                            GUIDE_F_N0B_CAP1: begin
                                guide_start_match <= guide_match_low &&
                                    (guide_rom_rd_data[8:0] == guide_tmp[8:0]);
                                guide_fstep       <= GUIDE_F_N1_REQ2;
                            end

                            GUIDE_F_N1_REQ2:
                                guide_fstep <= GUIDE_F_N1_CAP2;

                            GUIDE_F_N1_CAP2: begin
                                guide_slot1_rem[15:7] <= guide_rom_rd_data[8:0];
                                // one group = same reference start + a
                                // different key + a real second entry
                                guide_group2 <= guide_start_match &&
                                    (guide_slot1_key != guide_slot0_key) &&
                                    ((guide_idx + 8'd1) < guide_count);
                                guide_group_last <=
                                    ((guide_idx + 8'd1) >= guide_count) ||
                                    (guide_start_match &&
                                     (guide_slot1_key != guide_slot0_key) &&
                                     ((guide_idx + 8'd2) >= guide_count));
                                guide_fstep <= GUIDE_F_READY;
                            end

                            GUIDE_F_READY: begin
                                if (frame_tick) begin
                                    // real activation frame A
                                    guide_state         <= GUIDE_S_ACTIVE;
                                    guide_slot0_done    <= 1'b0;
                                    guide_slot1_done    <= ~guide_group2;
                                    guide_slot1_valid   <= guide_group2;
                                    guide_green_pending <= {guide_group2, 1'b1};
                                    guide_idx <= guide_idx +
                                                 (guide_group2 ? 8'd2 : 8'd1);

                                    if (guide_act_hit0) begin
                                        guide_score    <= guide_score + 8'd1;
                                        guide_progress <= guide_progress + 8'd1;
                                        guide_slot0_done <= 1'b1;
                                        guide_gray_pending[guide_slot0_key] <= 1'b1;
                                        guide_green_pending[0] <= 1'b0;
                                        guide_status_dirty <= 1'b1;
                                        if (guide_red_shown &&
                                            (guide_red_key == guide_slot0_key))
                                            guide_red_shown <= 1'b0;
                                    end
                                    if (guide_act_hit1) begin
                                        guide_score    <= guide_score + 8'd1;
                                        guide_progress <= guide_progress + 8'd1;
                                        guide_slot1_done <= 1'b1;
                                        guide_gray_pending[guide_slot1_key] <= 1'b1;
                                        guide_green_pending[1] <= 1'b0;
                                        guide_status_dirty <= 1'b1;
                                        if (guide_red_shown &&
                                            (guide_red_key == guide_slot1_key))
                                            guide_red_shown <= 1'b0;
                                    end
                                    if (guide_act_wrong != 12'd0) begin
                                        if (guide_error != 16'hFFFF)
                                            guide_error <= guide_error + 16'd1;
                                        if (!guide_red_pending && !guide_red_shown &&
                                            !(guide_frame_active &&
                                              (guide_frame_kind == GUIDE_K_RED))) begin
                                            guide_red_pending <= 1'b1;
                                            guide_red_key <=
                                                guide_low_key12(guide_act_wrong);
                                        end
                                    end

                                    // start both per-slot windows at age 0
                                    if (!guide_act_hit0)
                                        guide_slot0_rem <= guide_slot0_rem - 16'd1;
                                    if (guide_group2 && !guide_act_hit1)
                                        guide_slot1_rem <= guide_slot1_rem - 16'd1;

                                    if ((guide_act_hit0 ||
                                         (guide_slot0_rem == 16'd0)) &&
                                        (!guide_group2 || guide_act_hit1 ||
                                         (guide_slot1_rem == 16'd0))) begin
                                        if (guide_group_last) begin
                                            guide_state        <= GUIDE_S_DONE_DRAIN;
                                            guide_done_req     <= 1'b1;
                                            guide_gray_all_req <= 1'b1;
                                            guide_gray_sweep   <= 4'd0;
                                            guide_gray_pending <= 12'd0;
                                            guide_green_pending<= 2'd0;
                                            guide_red_pending  <= 1'b0;
                                            guide_red_shown    <= 1'b0;
                                            guide_status_hold  <= 1'b1;
                                        end else begin
                                            guide_state <= GUIDE_S_FETCH;
                                            guide_fstep <= GUIDE_F_START;
                                        end
                                    end
                                end
                            end

                            default: guide_fstep <= GUIDE_F_IDX0_REQ;
                        endcase
                    end

                    GUIDE_S_ACTIVE: begin
                        if (frame_tick) begin
                            // score / progress / settled flags
                            if (guide_hit0 || guide_hit1 ||
                                guide_timeout0 || guide_timeout1) begin
                                guide_score <= guide_score +
                                               {7'd0, guide_hit0} +
                                               {7'd0, guide_hit1};
                                guide_progress <= guide_progress +
                                                  {7'd0, guide_hit0} +
                                                  {7'd0, guide_hit1} +
                                                  {7'd0, guide_timeout0} +
                                                  {7'd0, guide_timeout1};
                                guide_status_dirty <= 1'b1;
                            end

                            if (guide_hit0 || guide_timeout0) begin
                                guide_slot0_done <= 1'b1;
                                guide_gray_pending[guide_slot0_key] <= 1'b1;
                                guide_green_pending[0] <= 1'b0;
                                if (guide_red_pending &&
                                    (guide_red_key == guide_slot0_key))
                                    guide_red_pending <= 1'b0;
                                if (guide_red_shown &&
                                    (guide_red_key == guide_slot0_key))
                                    guide_red_shown <= 1'b0;
                            end
                            if (guide_hit1 || guide_timeout1) begin
                                guide_slot1_done <= 1'b1;
                                guide_gray_pending[guide_slot1_key] <= 1'b1;
                                guide_green_pending[1] <= 1'b0;
                                if (guide_red_pending &&
                                    (guide_red_key == guide_slot1_key))
                                    guide_red_pending <= 1'b0;
                                if (guide_red_shown &&
                                    (guide_red_key == guide_slot1_key))
                                    guide_red_shown <= 1'b0;
                            end

                            // errors: one wrong-key event per audio frame,
                            // plus one per slot that expires this frame
                            if (guide_err_sum > 17'h0FFFF)
                                guide_error <= 16'hFFFF;
                            else
                                guide_error <= guide_error + {14'd0, guide_err_inc};

                            if (guide_any_wrong) begin
                                if (!guide_red_pending && !guide_red_shown &&
                                    !(guide_frame_active &&
                                      (guide_frame_kind == GUIDE_K_RED))) begin
                                    guide_red_pending <= 1'b1;
                                    guide_red_key <=
                                        guide_low_key12(guide_wrong_mask);
                                end
                            end

                            // window countdown (age D is already outside)
                            if (!guide_slot0_done && !guide_hit0 &&
                                !guide_timeout0 && (guide_slot0_rem != 16'd0))
                                guide_slot0_rem <= guide_slot0_rem - 16'd1;
                            if (guide_slot1_valid && !guide_slot1_done &&
                                !guide_hit1 && !guide_timeout1 &&
                                (guide_slot1_rem != 16'd0))
                                guide_slot1_rem <= guide_slot1_rem - 16'd1;

                            // whole-group settlement
                            if ((guide_slot0_done || guide_hit0 || guide_timeout0) &&
                                (guide_slot1_done || guide_hit1 || guide_timeout1)) begin
                                if (guide_group_last) begin
                                    guide_state        <= GUIDE_S_DONE_DRAIN;
                                    guide_done_req     <= 1'b1;
                                    guide_gray_all_req <= 1'b1;
                                    guide_gray_sweep   <= 4'd0;
                                    guide_gray_pending <= 12'd0;
                                    guide_green_pending<= 2'd0;
                                    guide_red_pending  <= 1'b0;
                                    guide_red_shown    <= 1'b0;
                                    guide_status_hold  <= 1'b1;
                                end else begin
                                    guide_state <= GUIDE_S_FETCH;
                                    guide_fstep <= GUIDE_F_START;
                                end
                            end

                            // red hold (~100 ms), then restore the key colour
                            if (guide_red_shown) begin
                                if (guide_timer >= (GUIDE_TICKS_RED - 18'd1)) begin
                                    guide_red_shown <= 1'b0;
                                    if ((guide_red_key == guide_slot0_key) &&
                                        !(guide_slot0_done || guide_hit0 ||
                                          guide_timeout0) &&
                                        (guide_slot0_rem > 16'd1)) begin
                                        guide_green_pending[0] <= 1'b1;
                                    end else if (guide_slot1_valid &&
                                                 (guide_red_key == guide_slot1_key) &&
                                                 !(guide_slot1_done || guide_hit1 ||
                                                   guide_timeout1) &&
                                                 (guide_slot1_rem > 16'd1)) begin
                                        guide_green_pending[1] <= 1'b1;
                                    end else begin
                                        guide_gray_pending[guide_red_key] <= 1'b1;
                                    end
                                end else begin
                                    guide_timer <= guide_timer + 18'd1;
                                end
                            end
                        end
                    end

                    GUIDE_S_DONE_DRAIN: begin
                        if (!guide_frame_active &&
                            (guide_gray_pending == 12'd0) &&
                            !guide_gray_all_req && !guide_done_req) begin
                            guide_state <= GUIDE_S_DONE_HOLD;
                            guide_timer <= 18'd0;
                        end
                    end

                    GUIDE_S_DONE_HOLD: begin
                        if (frame_tick) begin
                            if (guide_timer >= (GUIDE_TICKS_5S - 18'd1)) begin
                                // auto replay the same song, full clear
                                guide_timer          <= 18'd0;
                                guide_state          <= GUIDE_S_ENTER;
                                guide_idx            <= 8'd0;
                                guide_count          <= 8'd0;
                                guide_start_addr     <= 9'd0;
                                guide_count_lo       <= 7'd0;
                                guide_fstep          <= GUIDE_F_IDX0_REQ;
                                guide_tmp            <= 12'd0;
                                guide_match_low      <= 1'b0;
                                guide_start_match    <= 1'b0;
                                guide_slot0_key      <= 4'd0;
                                guide_slot1_key      <= 4'd0;
                                guide_slot0_done     <= 1'b1;
                                guide_slot1_done     <= 1'b1;
                                guide_slot1_valid    <= 1'b0;
                                guide_slot0_rem      <= 16'd0;
                                guide_slot1_rem      <= 16'd0;
                                guide_group2         <= 1'b0;
                                guide_group_last     <= 1'b0;
                                guide_score          <= 8'd0;
                                guide_progress       <= 8'd0;
                                guide_error          <= 16'd0;
                                guide_green_pending  <= 2'd0;
                                guide_gray_pending   <= 12'd0;
                                guide_gray_all_req   <= 1'b1;
                                guide_gray_sweep     <= 4'd0;
                                guide_red_pending    <= 1'b0;
                                guide_red_shown      <= 1'b0;
                                guide_status_dirty   <= 1'b1;
                                guide_status_hold    <= 1'b0;
                                guide_done_req       <= 1'b0;
                                guide_idle_req       <= 1'b0;
                                guide_flush_soft     <= 1'b1;
                            end else begin
                                guide_timer <= guide_timer + 18'd1;
                            end
                        end
                    end

                    GUIDE_S_EXIT_DRAIN: begin
                        if (!guide_frame_active &&
                            (guide_gray_pending == 12'd0) &&
                            !guide_gray_all_req &&
                            !guide_done_req && !guide_idle_req) begin
                            guide_state <= GUIDE_S_EXIT_HOLD;
                            guide_timer <= 18'd0;
                        end
                    end

                    GUIDE_S_EXIT_HOLD: begin
                        if (frame_tick) begin
                            if (guide_timer >= (GUIDE_TICKS_2S - 18'd1)) begin
                                guide_idle_req    <= 1'b1;
                                guide_state       <= GUIDE_S_OFF;
                                guide_status_hold <= 1'b1;
                                guide_timer       <= 18'd0;
                            end else begin
                                guide_timer <= guide_timer + 18'd1;
                            end
                        end
                    end

                    default: guide_state <= GUIDE_S_OFF;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // 014-A screen frame producer, 16-byte register FIFO, UART adapter
    // ------------------------------------------------------------------
    // FIFO: depth 16, 0 BSRAM. The array is deliberately small and has an
    // asynchronous read port, so it infers distributed logic, not a block.
    reg [4:0]  guide_fifo_wr_ptr;
    reg [4:0]  guide_fifo_rd_ptr;
    (* syn_ramstyle = "distributed_ram" *) reg [7:0] guide_fifo_mem [0:15];

    // UART adapter / byte transmitter state.
    reg [1:0]  guide_uart_state;
    reg        guide_uart_send;
    reg        guide_tx_last;
    reg        guide_tx_pop;
    reg [1:0]  guide_owner;
    reg [15:0] guide_byte_count;
    reg [7:0]  guide_frame_count_total;
    reg [7:0]  guide_drop_count;

    // ROM read controls (combinational, one request per REQ step).
    reg        guide_rom_rd_en;
    reg [9:0]  guide_rom_rd_addr;

    wire [4:0] guide_fifo_count = guide_fifo_wr_ptr - guide_fifo_rd_ptr;
    wire [7:0] guide_fifo_head  = guide_fifo_mem[guide_fifo_rd_ptr[3:0]];

    wire [9:0]  guide_nidx  = {1'b0, guide_start_addr} + {2'b0, guide_idx};
    wire [10:0] guide_nidx3 = {1'b0, guide_nidx};
    wire [10:0] guide_nbase = 11'd16 + guide_nidx3 + guide_nidx3 + guide_nidx3;

    wire guide_phy_busy;
    wire guide_phy_txd;

    // ------------------------------------------------------------------
    // Frame selection (priority order from the work order)
    // ------------------------------------------------------------------
    wire        guide_play_gray_need = (guide_gray_pending != 12'd0);
    wire [3:0]  guide_play_gray_key  = guide_low_key12(guide_gray_pending);
    wire        guide_status_need    = guide_status_dirty &&
                                       !guide_status_hold &&
                                       (guide_count != 8'd0);

    wire [2:0] guide_sel_kind =
        guide_gray_all_req     ? GUIDE_K_GRAY   :
        guide_play_gray_need   ? GUIDE_K_GRAY   :
        guide_done_req         ? GUIDE_K_DONE   :
        guide_idle_req         ? GUIDE_K_IDLE   :
        guide_status_need      ? GUIDE_K_STATUS :
        guide_green_pending[0] ? GUIDE_K_GREEN  :
        guide_green_pending[1] ? GUIDE_K_GREEN  :
        guide_red_pending      ? GUIDE_K_RED    : GUIDE_K_NONE;

    wire [3:0] guide_sel_key =
        guide_gray_all_req     ? guide_gray_sweep :
        guide_play_gray_need   ? guide_play_gray_key :
        guide_green_pending[0] ? guide_slot0_key :
        guide_green_pending[1] ? guide_slot1_key :
        guide_red_pending      ? guide_red_key : 4'd0;

    wire [5:0] guide_sel_len = guide_frame_len_f(
        guide_sel_kind, guide_sel_key, guide_song, guide_count,
        guide_progress, guide_score);

    // ------------------------------------------------------------------
    // UART ownership / arbitration (LAT has priority at frame boundaries)
    // ------------------------------------------------------------------
    wire fx_uart_mux_lat_work = (lat_exp_state != LAT_EXP_S_IDLE) ||
                                lat_exp_pending_valid ||
                                lat_exp_ready_pending ||
                                lat_exp_capture;

    wire guide_exit_seq = (guide_state == GUIDE_S_EXIT_DRAIN);

    // A screen frame that has not transmitted its first byte yields to a
    // waiting LAT frame at the next boundary; a started frame is never
    // preempted and the LAT is held in PREPARE by lat_exp_tx_busy.
    wire guide_yield_now = (guide_owner == FX_UART_OWN_SCR) &&
                           !guide_frame_started &&
                           fx_uart_mux_lat_work &&
                           !guide_exit_seq;

    wire guide_tx_issue_now = (guide_owner == FX_UART_OWN_SCR) &&
                              (guide_uart_state == GUIDE_UART_IDLE) &&
                              (guide_fifo_count != 5'd0) &&
                              !guide_phy_busy && !guide_yield_now;

    // A frame becomes committed as soon as its first byte is issued; only
    // an untouched soft frame may be merged/dropped.
    wire guide_frame_committed = guide_frame_started ||
                                 (guide_uart_state != GUIDE_UART_IDLE) ||
                                 guide_tx_issue_now;

    wire guide_green_key_valid =
        ((guide_frame_key == guide_slot0_key) && !guide_slot0_done &&
         (guide_slot0_rem != 16'd0)) ||
        (guide_slot1_valid && (guide_frame_key == guide_slot1_key) &&
         !guide_slot1_done && (guide_slot1_rem != 16'd0));

    wire guide_status_stale = (guide_frame_prog  != guide_progress) ||
                              (guide_frame_score != guide_score)    ||
                              (guide_frame_count != guide_count)    ||
                              (guide_frame_song  != guide_song);

    wire guide_abort = guide_frame_active && !guide_frame_committed &&
        ( ((guide_frame_kind == GUIDE_K_GREEN) &&
           ((guide_state != GUIDE_S_ACTIVE) || !guide_green_key_valid)) ||
          ((guide_frame_kind == GUIDE_K_RED) &&
           (guide_gray_pending[guide_frame_key] ||
            guide_flush_soft || guide_status_hold)) ||
          ((guide_frame_kind == GUIDE_K_STATUS) &&
           (guide_status_hold || guide_flush_soft || guide_status_stale)) );

    // ------------------------------------------------------------------
    // Producer: start a frame, snapshot its fields, feed the FIFO
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            guide_frame_kind        <= GUIDE_K_NONE;
            guide_frame_key         <= 4'd0;
            guide_frame_idx         <= 5'd0;
            guide_frame_len         <= 6'd0;
            guide_frame_active      <= 1'b0;
            guide_frame_started     <= 1'b0;
            guide_frame_is_sweep    <= 1'b0;
            guide_frame_prog        <= 8'd0;
            guide_frame_score       <= 8'd0;
            guide_frame_count       <= 8'd0;
            guide_frame_song        <= 2'd0;
            guide_frame_start_pulse <= 1'b0;
            guide_fifo_wr_ptr       <= 5'd0;
            guide_fifo_rd_ptr       <= 5'd0;
        end else begin
            guide_frame_start_pulse <= 1'b0;

            // last stop bit finished: the frame is no longer active
            if (guide_frame_done_pulse) begin
                guide_frame_active  <= 1'b0;
                guide_frame_started <= 1'b0;
                guide_frame_idx     <= 5'd0;
            end

            // merge/drop an untouched soft frame and discard its bytes
            if (guide_abort) begin
                guide_frame_active  <= 1'b0;
                guide_frame_started <= 1'b0;
                guide_frame_idx     <= 5'd0;
                guide_fifo_rd_ptr   <= guide_fifo_wr_ptr;
            end

            // physical TX accepted one byte: advance the read pointer
            if (guide_tx_pop) begin
                guide_fifo_rd_ptr   <= guide_fifo_rd_ptr + 5'd1;
                guide_frame_started <= 1'b1;
            end

            // start only on a clean boundary with an empty FIFO
            if (!guide_frame_active && !guide_abort &&
                !guide_frame_done_pulse && (guide_fifo_count == 5'd0) &&
                (guide_sel_kind != GUIDE_K_NONE)) begin
                guide_frame_kind        <= guide_sel_kind;
                guide_frame_key         <= guide_sel_key;
                guide_frame_idx         <= 5'd0;
                guide_frame_len         <= guide_sel_len;
                guide_frame_active      <= 1'b1;
                guide_frame_started     <= 1'b0;
                guide_frame_is_sweep    <= guide_gray_all_req;
                guide_frame_prog        <= guide_progress;
                guide_frame_score       <= guide_score;
                guide_frame_count       <= guide_count;
                guide_frame_song        <= guide_song;
                guide_frame_start_pulse <= 1'b1;
            end

            // stream the frame into the 16-byte FIFO
            if (guide_frame_active && !guide_abort &&
                (guide_frame_idx < guide_frame_len) &&
                (guide_fifo_count != 5'd16)) begin
                guide_fifo_mem[guide_fifo_wr_ptr[3:0]] <=
                    guide_frame_char_f(guide_frame_kind,
                                       guide_frame_idx,
                                       guide_frame_key,
                                       guide_frame_song,
                                       guide_frame_count,
                                       guide_frame_prog,
                                       guide_frame_score);
                guide_fifo_wr_ptr <= guide_fifo_wr_ptr + 5'd1;
                guide_frame_idx   <= guide_frame_idx + 5'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Byte transmitter handshake + physical UART owner
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            guide_uart_state        <= GUIDE_UART_IDLE;
            guide_uart_send         <= 1'b0;
            guide_tx_last           <= 1'b0;
            guide_tx_pop            <= 1'b0;
            guide_owner             <= FX_UART_OWN_NONE;
            guide_frame_done_pulse  <= 1'b0;
            guide_byte_count        <= 16'd0;
            guide_frame_count_total <= 8'd0;
            guide_drop_count        <= 8'd0;
        end else begin
            guide_uart_send        <= 1'b0;
            guide_tx_pop           <= 1'b0;
            guide_frame_done_pulse <= 1'b0;

            // observable counters (TB probes)
            if (guide_frame_done_pulse) begin
                guide_byte_count <= guide_byte_count + {10'd0, guide_frame_len};
                if (guide_frame_count_total != 8'hFF)
                    guide_frame_count_total <= guide_frame_count_total + 8'd1;
            end
            if (guide_abort &&
                ((guide_frame_kind == GUIDE_K_GREEN) ||
                 (guide_frame_kind == GUIDE_K_RED)) &&
                (guide_drop_count != 8'hFF))
                guide_drop_count <= guide_drop_count + 8'd1;

            // ------------------ ownership -------------------------------
            case (guide_owner)
                FX_UART_OWN_NONE: begin
                    if (fx_uart_mux_lat_work && !guide_exit_seq)
                        guide_owner <= FX_UART_OWN_LAT;
                    // W21: a key-light frame owns AB22 atomically.
                    else if ((guide_fifo_count != 5'd0) && !kl_busy)
                        guide_owner <= FX_UART_OWN_SCR;
                end
                FX_UART_OWN_LAT: begin
                    if (!fx_uart_mux_lat_work && !guide_phy_busy)
                        guide_owner <= FX_UART_OWN_NONE;
                end
                FX_UART_OWN_SCR: begin
                    if (guide_frame_done_pulse ||
                        (!guide_frame_active && !guide_frame_started) ||
                        (guide_yield_now &&
                         (guide_uart_state == GUIDE_UART_IDLE) &&
                         !guide_phy_busy))
                        guide_owner <= FX_UART_OWN_NONE;
                end
                default: guide_owner <= FX_UART_OWN_NONE;
            endcase

            // ------------------ byte handshake --------------------------
            case (guide_uart_state)
                GUIDE_UART_IDLE: begin
                    if ((guide_owner == FX_UART_OWN_SCR) &&
                        (guide_fifo_count != 5'd0) && !guide_phy_busy &&
                        !guide_yield_now) begin
                        guide_uart_send  <= 1'b1;
                        guide_tx_last    <= (guide_frame_idx == guide_frame_len) &&
                                            (guide_fifo_count == 5'd1);
                        guide_uart_state <= GUIDE_UART_WAIT_ACCEPT;
                    end
                end
                GUIDE_UART_WAIT_ACCEPT: begin
                    if (guide_phy_busy) begin
                        guide_tx_pop     <= 1'b1;
                        guide_uart_state <= GUIDE_UART_WAIT_DONE;
                    end
                end
                GUIDE_UART_WAIT_DONE: begin
                    if (!guide_phy_busy) begin
                        if (guide_tx_last)
                            guide_frame_done_pulse <= 1'b1;
                        guide_uart_state <= GUIDE_UART_IDLE;
                    end
                end
                default: guide_uart_state <= GUIDE_UART_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // ROM read address (combinational; one word per REQ step)
    // ------------------------------------------------------------------
    always @* begin
        guide_rom_rd_en   = 1'b0;
        guide_rom_rd_addr = 10'd0;
        if (guide_state == GUIDE_S_FETCH) begin
            case (guide_fstep)
                GUIDE_F_IDX0_REQ: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = {7'd0, guide_song, 1'b0};
                end
                GUIDE_F_IDX1_REQ: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = {7'd0, guide_song, 1'b0} + 10'd1;
                end
                GUIDE_F_N0_REQ0, GUIDE_F_N0B_REQ0: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0];
                end
                GUIDE_F_N0_REQ1, GUIDE_F_N0B_REQ1: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0] + 10'd1;
                end
                GUIDE_F_N0_REQ2: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0] + 10'd2;
                end
                GUIDE_F_N1_REQ0: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0] + 10'd3;
                end
                GUIDE_F_N1_REQ1: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0] + 10'd4;
                end
                GUIDE_F_N1_REQ2: begin
                    guide_rom_rd_en   = 1'b1;
                    guide_rom_rd_addr = guide_nbase[9:0] + 10'd5;
                end
                default: ;
            endcase
        end
    end

    song_rom u_song_rom (
        .clk               (clk),
        .rst_n             (rst_n),
        .guide_rom_rd_en   (guide_rom_rd_en),
        .guide_rom_rd_addr (guide_rom_rd_addr),
        .guide_rom_rd_data (guide_rom_rd_data),
        .guide_rom_rd_valid(guide_rom_rd_valid)
    );

    // ------------------------------------------------------------------
    // Physical UART mux: one uart_tx instance, DIV=434 unchanged
    // ------------------------------------------------------------------
    wire [7:0] fx_uart_mux_data = (guide_owner == FX_UART_OWN_LAT) ?
                                  lat_exp_tx_data :
                                  (guide_owner == FX_UART_OWN_SCR) ?
                                  guide_fifo_head : 8'h00;

    wire fx_uart_mux_send = (guide_owner == FX_UART_OWN_LAT) ?
                            lat_exp_tx_send :
                            (guide_owner == FX_UART_OWN_SCR) ?
                            guide_uart_send : 1'b0;

    // LAT busy feedback: the LAT may only believe a byte was accepted while
    // it really owns the physical transmitter.
    wire fx_uart_mux_lat_busy = (guide_owner == FX_UART_OWN_LAT) ?
                                guide_phy_busy : 1'b1;

    assign lat_exp_tx_busy = fx_uart_mux_lat_busy;
    assign lat_exp_tx_txd  = guide_phy_txd;
    assign uart_txd        = guide_phy_txd;

    // ========================================================================
    // W9/W10 status text -> screen, ONE fixed 40-byte stream
    // (L1 催办 15:52 + 工单追加 §四·补 ⑤, 方案 D: st0 整行替换禁写 -> revb)
    // ========================================================================
    // On every vib_level OR rev_state CHANGE this engine streams exactly
    //     sbrx.txt="VIB n" FF FF FF         19 bytes  (i =  0..18)
    //     revb.txt="REV:xxx" FF FF FF       21 bytes  (i = 19..39)
    //     ---------------------------------  40 bytes total, fixed length
    // to AB22 through u_uart_txd2, back to back in one burst.  The revb
    // payload is 7 characters, space-padded: "REV:OFF" / "REV:R0 " / "REV:R1 "
    // / "REV:R2 " (rev_state: 0=OFF, 1..3 = room 0..2) -- the padding is what
    // keeps the frame length fixed.  revb is the REV BUTTON's own objname
    // (screen side renames b0 -> revb): TJC ".txt=" replaces the WHOLE line,
    // so the old st0 plan (page-1 shared status line) was dropped -- writing
    // st0 would wipe the other content on that line.
    //
    // 🔴 BOOT FRAME: one burst is sent right after reset release ("VIB 0" +
    // "REV:OFF"), so the REV button shows its state without needing a press
    // first.  Edge-triggered afterwards:
    //
    // 🔴 EDGE-TRIGGERED ONLY (hard constraint ②): a frame is issued when the
    // level/state CHANGES and never periodically -- a periodic resend would
    // contend with the follow-along lights on uart_txd2 and stall/corrupt the
    // panel.  A change DURING a burst restarts the burst (the tail then
    // describes the newest state); a damping (0x0E) change sends NOTHING (no
    // widget shows it).
    //
    // Arbitration: the guide engine owns AB22 only while guide_owner ==
    // FX_UART_OWN_SCR.  A status byte is issued only while that is false; if
    // ownership is taken mid-frame the engine PAUSES (byte index held) and
    // resumes when the bus frees.  A byte whose send pulse was already issued
    // when ownership flips can still be cut in half -- worst case one status
    // update is lost or garbled, the panel drops the malformed buffer (it only
    // executes a buffer ending in FF FF FF) and the next state change
    // re-syncs.  Cosmetic-only by construction and no guide-engine change.
    // Pacing is a cycle counter (>= 10 bit times per byte at DIV=434), so no
    // extra busy wire is needed.
    // 12 bit times per byte: uart_tx samples `send` ONLY in S_IDLE and a byte
    // occupies exactly 10 bit times, so a 10-bit gap makes every pulse after
    // the first land on the S_STOP->S_IDLE edge and be LOST (first directed-TB
    // run received exactly 1 of 18 bytes).  12 bits = 2 bit times of margin.
    localparam integer STA_TX_LEN     = 40;
    localparam integer STA_TX_GAP_CYC = 12 * 434;

    reg        sta_tx_run;
    reg [5:0]  sta_tx_idx;                // 0..39
    reg [15:0] sta_tx_gap;
    reg [1:0]  vib_level_q;
    reg [1:0]  rev_state_q;
    reg        sta_boot_pending;          // one initial burst after reset

    // W21: the status stream must not insert a byte while a key-light frame
    // owns AB22 (two TJC buffers spliced together are both dropped).
    wire       sta_tx_free  = (guide_owner != FX_UART_OWN_SCR) && !kl_busy;
    wire       sta_tx_tick  = (sta_tx_gap == 16'd0);
    wire       sta_change   = (vib_level != vib_level_q) ||
                             (rev_state_v != rev_state_q);
    wire       sta_tx_issue = sta_tx_run && sta_tx_tick && sta_tx_free;

    function [7:0] sta_tx_byte;
        input [5:0] i;
        input [1:0] n;                   // vib level, live
        input [1:0] s;                   // rev state, live (0=OFF, 1..3=R0..R2)
        begin
            case (i)
                // ---- sbrx.txt="VIB n" FF FF FF   (19 bytes, i = 0..18) ----
                6'd0:    sta_tx_byte = 8'h73;  // 's'
                6'd1:    sta_tx_byte = 8'h62;  // 'b'
                6'd2:    sta_tx_byte = 8'h72;  // 'r'
                6'd3:    sta_tx_byte = 8'h78;  // 'x'
                6'd4:    sta_tx_byte = 8'h2E;  // '.'
                6'd5:    sta_tx_byte = 8'h74;  // 't'
                6'd6:    sta_tx_byte = 8'h78;  // 'x'
                6'd7:    sta_tx_byte = 8'h74;  // 't'
                6'd8:    sta_tx_byte = 8'h3D;  // '='
                6'd9:    sta_tx_byte = 8'h22;  // '"'
                6'd10:   sta_tx_byte = 8'h56;  // 'V'
                6'd11:   sta_tx_byte = 8'h49;  // 'I'
                6'd12:   sta_tx_byte = 8'h42;  // 'B'
                6'd13:   sta_tx_byte = 8'h20;  // ' '
                6'd14:   sta_tx_byte = 8'h30 + {4'd0, n};  // '0'..'3'
                6'd15:   sta_tx_byte = 8'h22;  // '"'
                6'd16:   sta_tx_byte = 8'hFF;  // terminator
                6'd17:   sta_tx_byte = 8'hFF;
                6'd18:   sta_tx_byte = 8'hFF;
                // ---- revb.txt="REV:OFF"/"REV:Rn " FF FF FF  (21 B, 19..39) --
                6'd19:   sta_tx_byte = 8'h72;  // 'r'
                6'd20:   sta_tx_byte = 8'h65;  // 'e'
                6'd21:   sta_tx_byte = 8'h76;  // 'v'
                6'd22:   sta_tx_byte = 8'h62;  // 'b'
                6'd23:   sta_tx_byte = 8'h2E;  // '.'
                6'd24:   sta_tx_byte = 8'h74;  // 't'
                6'd25:   sta_tx_byte = 8'h78;  // 'x'
                6'd26:   sta_tx_byte = 8'h74;  // 't'
                6'd27:   sta_tx_byte = 8'h3D;  // '='
                6'd28:   sta_tx_byte = 8'h22;  // '"'
                6'd29:   sta_tx_byte = 8'h52;  // 'R'
                6'd30:   sta_tx_byte = 8'h45;  // 'E'
                6'd31:   sta_tx_byte = 8'h56;  // 'V'
                6'd32:   sta_tx_byte = 8'h3A;  // ':'
                6'd33:   sta_tx_byte = (s == 2'd0) ? 8'h4F : 8'h52;   // 'O'/'R'
                6'd34:   sta_tx_byte = (s == 2'd0) ? 8'h46
                                       : (8'h30 + {4'd0, s - 2'd1});  // 'F'/'0'..'2'
                6'd35:   sta_tx_byte = (s == 2'd0) ? 8'h46 : 8'h20;   // 'F'/' '
                6'd36:   sta_tx_byte = 8'h22;  // '"'
                6'd37:   sta_tx_byte = 8'hFF;  // terminator
                6'd38:   sta_tx_byte = 8'hFF;
                6'd39:   sta_tx_byte = 8'hFF;
                default: sta_tx_byte = 8'hFF;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sta_tx_run       <= 1'b0;
            sta_tx_idx       <= 6'd0;
            sta_tx_gap       <= 16'd0;
            vib_level_q      <= 2'd0;
            rev_state_q      <= 2'd0;
            sta_boot_pending <= 1'b1;      // fire the initial state once
        end else begin
            vib_level_q <= vib_level;
            rev_state_q <= rev_state_v;
            if (!sta_tx_run) begin
                if (sta_change || sta_boot_pending) begin
                    sta_boot_pending <= 1'b0;
                    sta_tx_run       <= 1'b1;
                    sta_tx_idx       <= 6'd0;
                    sta_tx_gap       <= 16'd0; // first byte issues next clk
                end
            end else if (sta_change) begin         // rapid re-step: restart
                sta_tx_idx <= 6'd0;
                sta_tx_gap <= 16'd0;
            end else if (sta_tx_issue) begin
                if (sta_tx_idx == (STA_TX_LEN - 1)) sta_tx_run <= 1'b0;
                else                                sta_tx_idx <= sta_tx_idx + 6'd1;
                sta_tx_gap <= STA_TX_GAP_CYC;
            end else if (sta_tx_gap != 16'd0) begin
                sta_tx_gap <= sta_tx_gap - 16'd1;
            end
        end
    end

    // W5c: AB22 takes the screen-directed frames only (see the u_uart_txd2
    // comment near the top of this module for why LAT text is excluded).
    // W9/W10: the 40-byte status stream above shares this transmitter; its
    // bytes go out only while the guide engine does not own AB22 (arbitration
    // note there).  The digits are read live, so a state change mid-burst
    // re-syncs the tail of the burst towards the new state.
    // W21: priority is guide frame > key-light frame > status burst.  The
    // key-light engine only starts a frame when the guide owns neither the
    // line nor a non-empty FIFO (see kl_env below), and both the guide owner
    // FSM and sta_tx_free are blocked while kl_busy is high, so the three
    // sources can never interleave bytes inside one TJC command.
    assign scr_txd2_data = (guide_owner == FX_UART_OWN_SCR) ? guide_fifo_head :
                           kl_busy ? kl_data :
                           sta_tx_run ?
                           sta_tx_byte(sta_tx_idx, vib_level, rev_state_v) : 8'h00;
    assign scr_txd2_send = (guide_owner == FX_UART_OWN_SCR) ? guide_uart_send :
                           kl_busy ? kl_send :
                           sta_tx_issue;

    uart_tx #(
        .DIV (434)                              // 50 MHz / 115200
    ) u_lat_uart_tx (
        .clk  (clk),
        .rst_n(rst_n),
        .data (fx_uart_mux_data),
        .send (fx_uart_mux_send),
        .txd  (guide_phy_txd),
        .busy (guide_phy_busy)
    );

    // ========================================================================
    // ========================================================================
    // W21: screen key follow (free play only) -- rtl/key_light.v
    // ========================================================================
    // pressed MPR121 electrode k  -> "bt<k>.bco=2016"  FF FF FF (green)
    // released                    -> "bt<k>.bco=33808" FF FF FF (idle gray)
    //   kl_mode : the guide engine is OFF (free play).  Leaving free play
    //             CLEARS the pending mask (the guide owns the panel then and
    //             its own gray sweep restores the whole keyboard).
    //   kl_env  : the AB22 line is free right now; delays, never drops, a frame.
    wire kl_mode = (guide_state == GUIDE_S_OFF);
    wire kl_env  = (guide_owner != FX_UART_OWN_SCR) &&
                   !guide_frame_active &&
                   (guide_fifo_count == 5'd0) &&
                   (guide_sel_kind == GUIDE_K_NONE) &&
                   !sta_tx_run;

    key_light #(
        .CLK_HZ   (50_000_000),
        .BAUD_DIV (434),
        .GAP_BITS (12)
    ) u_key_light (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (kl_mode),
        .start_ok (kl_env),
        .key_on   (key_on[11:0]),
        .key_off  (key_off[11:0]),
        .key_held (key_held[11:0]),
        .data     (kl_data),
        .send     (kl_send),
        .busy     (kl_busy)
    );

    // Amplifier enable
    // ========================================================================
    // Hard tied LOW: PA_EN = 0 enables the NS4263. Kept as an explicit assign
    // (not a constant in the port list) so a future mute/soft-start has an
    // obvious place to hook in.
    assign PA_EN = 1'b0;

    // ========================================================================
    // LEDs (common anode -> driving LOW lights them)
    // ========================================================================
    // SubTask-004-A: the I2C bus took P16 (was led[3]) and R17 (was led[2]), so
    // exactly two indicators are left (R18 / T18, see the header note):
    //   led[0] : POR released                       -> "configured and running"
    //   led[1] : at least one pool voice is sounding -> "playing"
    // The old led[1] ("any key held") and led[2] (test-mode ~3 Hz blink) are gone
    // together with the blink_cnt counter that only served led[2]. Losing the
    // blink indicator in test mode is the direct consequence of "the LEDs give
    // way to the I2C bus"; the test-mode LOGIC is unchanged.
    assign led[0] = ~por_n;                                  // on after POR
    assign led[1] = ~(|v_active);                            // a voice is sounding

    // ========================================================================
    // D2 (first batch): DDR3 single-tap echo
    // ------------------------------------------------------------------------
    // x[n] = sample_trem (valid from clk#17); echo captures clk#18, service q is
    // stable clk#32, mix registers clk#33; PT8211 latches at the next frame_tick
    // -> no extra audio-frame latency. Echo OFF is a pure combinational mux.
    //
    // Commands (allocated after the full existing table):
    //   0x13 : echo on/off toggle (default OFF)
    //   0x14 : echo delay 0.5 -> 1 -> 2 -> 4 -> 0.5 s
    // Page-0 addendum (2026-10-31): the screen's ECHO / ECHO LEN keys OR in
    // here and act on exactly the same two ports, so the PC bytes and the
    // screen keys are behaviour-identical.  fx_ddr_echo itself is untouched.
    // ========================================================================
    wire uart_echo_toggle = (rx_done_eff && (rx_data == 8'h13)) || ev_echo;
    wire uart_echo_dly    = (rx_done_eff && (rx_data == 8'h14)) || ev_echo_dly;

    // POR-synced DDR3 reset: AA13 stays the audio key[0]; DDR3 never takes it.
    reg [1:0] ddr_reset_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ddr_reset_sync <= 2'b00;
        else        ddr_reset_sync <= {ddr_reset_sync[0], 1'b1};
    end
    wire ddr_ip_rst_n = ddr_reset_sync[1];

    wire                   memory_clk;
    wire                   ddr_pll_lock;
    wire [7:0]             ddr_mdr_do;
    wire [1:0]             ddr_mdr_opc;
    wire                   ddr_mdr_ainc;
    wire [7:0]             ddr_mdr_di;
    wire                   ddr_pll_stop;

    ddr3_pll_ctrl u_ddr3_pll_ctrl(
        .clk        (clk),
        .rst_n      (ddr_ip_rst_n),
        .pll_lock   (ddr_pll_lock),
        .pll_stop   (ddr_pll_stop),
        .mdrp_rdata (ddr_mdr_do),
        .mdrp_op    (ddr_mdr_opc),
        .mdrp_inc   (ddr_mdr_ainc),
        .mdrp_wdata (ddr_mdr_di)
    );

    DDR_PLL Gowin_PLL_ddr(
        .clkin   (clk),
        .clkout0 (),
        .clkout1 (),
        .clkout2 (memory_clk),
        .lock    (ddr_pll_lock),
        .reset   (~rst_n),
        .mdclk   (clk),
        .mdopc   (ddr_mdr_opc),
        .mdainc  (ddr_mdr_ainc),
        .mdrdo   (ddr_mdr_do),
        .mdwdi   (ddr_mdr_di)
    );

    wire        ddr_ui_clk;
    wire        ddr_rst;
    wire        init_calib_complete;
    wire        ddr_cmd_ready;
    wire        ddr_wr_data_rdy;
    wire        ddr_rd_data_valid;
    wire        ddr_rd_data_end;
    wire [127:0] ddr_rd_data;
    wire [2:0]  ddr_cmd;
    wire        ddr_cmd_en;
    wire [28:0] ddr_native_addr;
    wire [127:0] ddr_wr_data;
    wire        ddr_wr_data_en;
    wire        ddr_wr_data_end;
    wire [15:0] ddr_wr_data_mask;

    DDR3MI u_ddr3(
        .clk                 (clk),
        .pll_stop            (ddr_pll_stop),
        .memory_clk          (memory_clk),
        .pll_lock            (ddr_pll_lock),
        .rst_n               (ddr_ip_rst_n),
        .clk_out             (ddr_ui_clk),
        .ddr_rst             (ddr_rst),
        .init_calib_complete (init_calib_complete),
        .cmd_ready           (ddr_cmd_ready),
        .cmd                 (ddr_cmd),
        .cmd_en              (ddr_cmd_en),
        .addr                (ddr_native_addr),
        .wr_data_rdy         (ddr_wr_data_rdy),
        .wr_data             (ddr_wr_data),
        .wr_data_en          (ddr_wr_data_en),
        .wr_data_end         (ddr_wr_data_end),
        .wr_data_mask        (ddr_wr_data_mask),
        .rd_data             (ddr_rd_data),
        .rd_data_valid       (ddr_rd_data_valid),
        .rd_data_end         (ddr_rd_data_end),
        .sr_req              (1'b0),
        .ref_req             (1'b0),
        .sr_ack              (),
        .ref_ack             (),
        .burst               (1'b1),
        .O_ddr_addr          (ddr_addr),
        .O_ddr_ba            (ddr_bank),
        .O_ddr_cs_n          (ddr_cs),
        .O_ddr_ras_n         (ddr_ras),
        .O_ddr_cas_n         (ddr_cas),
        .O_ddr_we_n          (ddr_we),
        .O_ddr_clk           (ddr_ck),
        .O_ddr_clk_n         (ddr_ck_n),
        .O_ddr_cke           (ddr_cke),
        .O_ddr_odt           (ddr_odt),
        .O_ddr_reset_n       (ddr_reset_n),
        .O_ddr_dqm           (ddr_dm),
        .IO_ddr_dq           (ddr_dq),
        .IO_ddr_dqs          (ddr_dqs),
        .IO_ddr_dqs_n        (ddr_dqs_n)
    );

    wire        svc_req_tgl, svc_req_iswr;
    wire [28:0] svc_req_addr;
    wire [127:0] svc_req_wdata;
    wire [15:0] svc_req_mask;
    wire        svc_ack_tgl;
    wire [127:0] svc_ack_rdata;
    wire        svc_ack_toerr;
    wire        svc_ui_ready;
    wire signed [15:0] echo_q0, echo_q1;
    wire        echo_q0_valid, echo_q1_valid;
    wire [31:0] svc_frame_seq, svc_hist_count;
    wire [15:0] svc_fault_count, svc_uf, svc_ov, svc_to, svc_tag;
    wire [7:0]  svc_fault_reason;
    wire [31:0] svc_req_max;
    wire        svc_ready;
    wire [1:0]  echo_tap0_sel, echo_tap1_sel;
    wire signed [15:0] echo_out;

    ddr3_ui_engine #(.TXN_TIMEOUT(65536)) u_ddr3_ui(
        .ui_clk              (ddr_ui_clk),
        .rst_n               (rst_n),
        .init_calib_complete (init_calib_complete),
        .ddr_rst             (ddr_rst),
        .req_tgl             (svc_req_tgl),
        .req_iswr            (svc_req_iswr),
        .req_addr            (svc_req_addr),
        .req_wdata           (svc_req_wdata),
        .req_mask            (svc_req_mask),
        .ack_tgl             (svc_ack_tgl),
        .ack_rdata           (svc_ack_rdata),
        .ack_toerr           (svc_ack_toerr),
        .req_ready           (svc_ui_ready),
        .cmd                 (ddr_cmd),
        .cmd_en              (ddr_cmd_en),
        .addr                (ddr_native_addr),
        .cmd_ready           (ddr_cmd_ready),
        .wr_data             (ddr_wr_data),
        .wr_data_en          (ddr_wr_data_en),
        .wr_data_end         (ddr_wr_data_end),
        .wr_data_mask        (ddr_wr_data_mask),
        .wr_data_rdy         (ddr_wr_data_rdy),
        .rd_data             (ddr_rd_data),
        .rd_data_valid       (ddr_rd_data_valid)
    );

    ddr_audio_service #(
        .N_SAMPLES   (262144),
        .FRAME_TICKS (1024),
        .CAP_SLOT    (18),
        .OUT_SLOT    (32),
        .UI_TIMEOUT  (65536)
    ) u_ddr_audio (
        .clk               (clk),
        .rst_n             (rst_n),
        .frame_tick        (frame_tick),
        .sample_in         ($signed(sample_trem)),
        .tap0_sel          (echo_tap0_sel),
        .tap1_sel          (echo_tap1_sel),
        .q0                (echo_q0),
        .q1                (echo_q1),
        .q0_valid          (echo_q0_valid),
        .q1_valid          (echo_q1_valid),
        .frame_seq_o       (svc_frame_seq),
        .hist_count_o      (svc_hist_count),
        .req_tgl           (svc_req_tgl),
        .req_iswr          (svc_req_iswr),
        .req_addr          (svc_req_addr),
        .req_wdata         (svc_req_wdata),
        .req_mask          (svc_req_mask),
        .ack_tgl           (svc_ack_tgl),
        .ack_rdata         (svc_ack_rdata),
        .ack_toerr         (svc_ack_toerr),
        .ui_req_ready      (svc_ui_ready),
        .ui_calib          (init_calib_complete),
        .ui_ddr_rst        (ddr_rst),
        .fault_count       (svc_fault_count),
        .fault_reason      (svc_fault_reason),
        .stat_underflow    (svc_uf),
        .stat_overflow     (svc_ov),
        .stat_timeout      (svc_to),
        .stat_tag_error    (svc_tag),
        .dbg_req_max_cycles(svc_req_max),
        .service_ready     (svc_ready)
    );

    fx_ddr_echo #(.FADE_LEN(256), .CAP_SLOT(18), .MIX_SLOT(33)) u_fx_ddr_echo(
        .clk            (clk),
        .rst_n          (rst_n),
        .frame_tick     (frame_tick),
        .sample_in      ($signed(sample_trem)),
        .enable_toggle  (uart_echo_toggle),
        .delay_cycle    (uart_echo_dly),
        .q0             (echo_q0),
        .q1             (echo_q1),
        .q0_valid       (echo_q0_valid),
        .q1_valid       (echo_q1_valid),
        .service_ready  (svc_ready),
        .tap0_sel       (echo_tap0_sel),
        .tap1_sel       (echo_tap1_sel),
        .sample_out     (echo_out),
        .dbg_state      (),
        .dbg_gain       ()
    );

    assign sample_l = echo_out;
    assign sample_r = echo_out;   // same mono echo result into both channels

    // keep status nets alive (debug via synthesis warnings is not needed)
    wire _d2_unused = &{1'b0, svc_frame_seq, svc_hist_count, svc_fault_count,
                        svc_fault_reason, svc_uf, svc_ov, svc_to, svc_tag,
                        svc_req_max, svc_ready};

endmodule

`default_nettype wire
