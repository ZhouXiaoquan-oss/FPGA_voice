// ============================================================================
// [p2_synth] Ported VERBATIM from this repo's phase-1 project:
//     project\p1_audio_test\rtl\pt8211_i2s_tx.v
// Only this ASCII provenance header was added; the module body is unchanged.
// Phase-1 status: verified by tb_pt8211_i2s_tx.v and on hardware (both
// channels audible), so phase 2 reuses it byte-for-byte.
// ============================================================================
// ============================================================================
// pt8211_i2s_tx -- I2S MASTER transmitter for PT8211-S (LSBJ / Japanese format)
// ============================================================================
// Why this is a rewrite, not a port, of the AX515 i2s_tx.v:
//
//   | item        | old i2s_tx.v (WM8731)      | this module (PT8211)      |
//   |-------------|----------------------------|---------------------------|
//   | role        | I2S SLAVE (bclk/lrclk in)  | I2S MASTER (generates)    |
//   | frame       | 32 slots per half-frame    | 16 BCK per half-frame     |
//   | WS polarity | LRCLK low  = LEFT          | WS low = RIGHT            |
//   | MSB phase   | delayed 1 BCK (Philips)    | aligned with WS edge      |
//   | LSB phase   | slot 16, then padding      | last BCK before WS flips  |
//
// Evidence -- PT8211 datasheet V1.7, page 4 (Figure 1 / Figure 2):
//   * Figure 1: WS = "RIGHT CH" (low) then "LEFT CH" (high)
//   * Figure 2: the MSB arrow sits AT the WS transition (no 1-bit delay);
//               the LSB arrow sits immediately before the next WS transition
//   * "Each valid DIN data will be shifted to the input register in the
//      rising edge of the BCK"      -> so we must update DIN on the FALLING edge
//   * "only the first 16bit data (from MSB) is valid if the input data length
//      is more than 16bits, other data bit will be truncated"
//   * "The DIN data must be the 2's complementary format and the MSB must be
//      the first."
//
// Waveform (DIV=16 -> BCK half period = 16 clk, WS period = 32 BCK):
//
//   BCK  __    __    __                                        __    __
//         \__/  \__/  \__/  ...                        ...  \__/  \__/
//   WS   _______________________________________________________
//        |<----------- RIGHT (16 bit) ---------->|<---- LEFT (16 bit) ---->
//   DIN   M  S  B ......................... L S B   M  S  B ....... L S B
//         ^                                       ^
//         |                                       |
//    WS flips + MSB here                   WS flips + MSB here
//    (LSB is the last bit before the flip -- that is "LSB justified")
//
// Timing contract:
//   * DIN (and WS when it changes) are updated on every BCK FALLING edge.
//   * PT8211 samples on the BCK RISING edge, so setup = half a BCK period.
//     With DIV=16: BCK = 1.5625 MHz, half period = 320 ns  (spec asks tH >= 25 ns).
//
// Sample coherence:
//   Both channels are latched at the frame boundary (start of the RIGHT
//   half-frame), so L and R come from the same sample instant. The right MSB
//   is taken straight from the input port at that edge, which is exactly the
//   value being latched -- so MSB and the remaining 15 bits always agree.
// ============================================================================

`default_nettype none

module pt8211_i2s_tx #(
    // Number of clk cycles per BCK HALF period.
    //   BCK     = clk / (2*DIV)
    //   Fws     = BCK / 32 = clk / (64*DIV)
    //   DIV=16  ->  BCK = 1.5625 MHz, Fws = 48.83 kHz   (default, ~48 kHz)
    //   DIV=8   ->  BCK = 3.125  MHz, Fws = 97.66 kHz
    //   DIV=4   ->  BCK = 6.25   MHz, Fws = 195.3 kHz
    //   DIV=3   ->  BCK = 8.33   MHz, Fws = 260.4 kHz   (still < 384 kHz max)
    parameter integer DIV = 16
)(
    input  wire        clk,         // system clock, 50 MHz on this board (V22)
    input  wire        rst_n,       // async reset, active low

    input  wire [15:0] sample_l,    // left  channel, two's complement
    input  wire [15:0] sample_r,    // right channel, two's complement

    output reg         bck,         // bit clock   -> PT8211 pin 1
    output reg         ws,          // word select -> PT8211 pin 2 (low = RIGHT)
    output reg         din,         // serial data -> PT8211 pin 3

    output wire        frame_tick   // 1-clk pulse at each frame boundary
);

    // ---------------------------------------------------------------- BCK gen
    // Toggle bck every DIV clk cycles; emit a 1-cycle pulse on the falling edge.
    reg  [15:0] div_cnt;
    reg         bck_fall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 16'd0;
            bck      <= 1'b1;          // idle high
            bck_fall <= 1'b0;
        end else begin
            bck_fall <= 1'b0;
            if (div_cnt == (DIV - 1)) begin
                div_cnt <= 16'd0;
                bck     <= ~bck;
                if (bck)               // 1 -> 0  == falling edge
                    bck_fall <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------- bit slot / channel FSM
    reg  [3:0]  n;          // 0..15, position inside the current half-frame
    reg  [15:0] lat_l;      // latched left  sample for this frame
    reg  [15:0] lat_r;      // latched right sample for this frame

    wire        next_ws    = ~ws;                  // WS value after this flip
    wire        half_start = (n == 4'd0);          // about to begin a half-frame
    wire        start_right = half_start & (next_ws == 1'b0);

    assign frame_tick = bck_fall & start_right;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n     <= 4'd0;
            ws    <= 1'b1;      // start by flipping into RIGHT (low)
            din   <= 1'b0;
            lat_l <= 16'd0;
            lat_r <= 16'd0;
        end else if (bck_fall) begin
            if (half_start) begin
                // ---- half-frame boundary: flip WS and present the new MSB ----
                ws <= next_ws;
                n  <= 4'd1;
                if (next_ws == 1'b0) begin
                    // entering RIGHT: also the frame boundary -> latch both channels
                    lat_l <= sample_l;
                    lat_r <= sample_r;
                    din   <= sample_r[15];      // == the value just latched
                end else begin
                    // entering LEFT: use the sample latched at the frame boundary
                    din   <= lat_l[15];
                end
            end else begin
                // ---- mid half-frame: shift out bits 14 down to 0 ----
                din <= ws ? lat_l[15 - n] : lat_r[15 - n];
                n   <= (n == 4'd15) ? 4'd0 : (n + 4'd1);
            end
        end
    end

endmodule

`default_nettype wire
